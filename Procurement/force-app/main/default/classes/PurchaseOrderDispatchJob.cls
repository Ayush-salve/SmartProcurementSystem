public with sharing class PurchaseOrderDispatchJob implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final String ENDPOINT = 'callout:Supplier_PO_API/purchase-orders';
    private static final Integer BATCH_SIZE = 20;

    private final List<Id> orderIds;

    public PurchaseOrderDispatchJob(List<Id> orderIds) {
        this.orderIds = orderIds;
    }

    public class DispatchOutcome {
        public Boolean success;
        public String externalId;
        public String message;
    }

    public void execute(QueueableContext context) {
        List<Id> current = new List<Id>();
        List<Id> remaining = new List<Id>();
        for (Integer i = 0; i < orderIds.size(); i++) {
            if (i < BATCH_SIZE) current.add(orderIds[i]); else remaining.add(orderIds[i]);
        }

        List<Purchase_Order__c> orders = [
            SELECT Id, Name, OwnerId, Status__c, Supplier__c, Supplier__r.Name, Warehouse__c, Order_Date__c,
                   Expected_Delivery__c, Total_Amount__c, Idempotency_Key__c, External_Order_Id__c, Sent_At__c,
                   (SELECT Product__r.Name, Quantity_Ordered__c, Unit_Price__c FROM Purchase_Order_Lines__r
                    WHERE Line_Status__c != 'Cancelled')
            FROM Purchase_Order__c WHERE Id IN :current
        ];

        List<Purchase_Order__c> updates = new List<Purchase_Order__c>();
        List<Map<String, Object>> notifications = new List<Map<String, Object>>();

        for (Purchase_Order__c po : orders) {
            if (String.isNotBlank(po.External_Order_Id__c) || po.Status__c != 'Sent') {
                continue;
            }
            DispatchOutcome outcome = dispatch(po);
            Purchase_Order__c upd = new Purchase_Order__c(Id = po.Id);
            if (outcome.success) {
                upd.Last_Sync_Status__c = 'Success';
                upd.External_Order_Id__c = outcome.externalId;
                if (po.Sent_At__c == null) upd.Sent_At__c = Datetime.now();
                notifications.add(buildNotification(po, 'Purchase order dispatched: ' + po.Name,
                    'Purchase order ' + po.Name + ' was sent to the supplier.', false));
            } else {
                // Return the order to Approved so it can be corrected and dispatched again.
                upd.Status__c = 'Approved';
                upd.Last_Sync_Status__c = 'Failed';
                upd.Sent_At__c = null;
                notifications.add(buildNotification(po, 'Purchase order dispatch failed: ' + po.Name,
                    'Dispatch of ' + po.Name + ' failed: ' + outcome.message + ' The order was returned to Approved.', true));
            }
            updates.add(upd);
        }

        if (!updates.isEmpty()) {
            update updates;
        }
        for (Map<String, Object> inputs : notifications) {
            notify(inputs);
        }

        if (!remaining.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new PurchaseOrderDispatchJob(remaining));
        }
    }

    // Callouts happen before any DML, as required for Queueable jobs that allow callouts.
    private static DispatchOutcome dispatch(Purchase_Order__c po) {
        DispatchOutcome outcome = new DispatchOutcome();
        outcome.success = false;
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(ENDPOINT);
            req.setMethod('POST');
            req.setTimeout(30000);
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Idempotency-Key', po.Idempotency_Key__c);
            req.setBody(buildPayload(po));
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                outcome.success = true;
                outcome.externalId = extractExternalId(res.getBody(), po);
            } else {
                outcome.message = 'Supplier endpoint returned HTTP ' + res.getStatusCode() + '.';
            }
        } catch (Exception e) {
            outcome.message = e.getMessage();
        }
        return outcome;
    }

    private static String buildPayload(Purchase_Order__c po) {
        List<Map<String, Object>> lines = new List<Map<String, Object>>();
        for (Purchase_Order_Line__c line : po.Purchase_Order_Lines__r) {
            lines.add(new Map<String, Object>{
                'product' => line.Product__r.Name,
                'quantity' => line.Quantity_Ordered__c,
                'unitPrice' => line.Unit_Price__c
            });
        }
        return JSON.serialize(new Map<String, Object>{
            'orderNumber' => po.Name,
            'supplier' => po.Supplier__r.Name,
            'orderDate' => po.Order_Date__c,
            'expectedDelivery' => po.Expected_Delivery__c,
            'totalAmount' => po.Total_Amount__c,
            'lines' => lines
        });
    }

    private static String extractExternalId(String body, Purchase_Order__c po) {
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
            for (String key : new List<String>{'orderId', 'id', 'externalId'}) {
                if (parsed.get(key) != null) return String.valueOf(parsed.get(key));
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.FINE, 'Non-JSON acknowledgement from supplier endpoint.');
        }
        return po.Idempotency_Key__c;
    }

    private static Map<String, Object> buildNotification(Purchase_Order__c po, String title, String message, Boolean createTask) {
        return new Map<String, Object>{
            'recordId' => String.valueOf(po.Id),
            'recipientId' => String.valueOf(po.OwnerId),
            'title' => title,
            'message' => message,
            'createTask' => createTask
        };
    }

    // Notification problems must never undo a completed dispatch.
    private static void notify(Map<String, Object> inputs) {
        try {
            Flow.Interview.createInterview('Procurement_Subflow_Notify', inputs).start();
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Dispatch notification skipped: ' + e.getMessage());
        }
    }
}
