public with sharing class ProcurementDispatchQueueable implements Queueable, Database.AllowsCallouts {

    // Orders handled per job; the rest are chained so one job never exceeds the callout limit.
    private static final Integer CHUNK_SIZE = 20;
    private static final Integer MAX_ERROR_LENGTH = 255;

    private final List<Id> orderIds;
    private final Integer attempt;

    public ProcurementDispatchQueueable(List<Id> orderIds, Integer attempt) {
        this.orderIds = orderIds;
        this.attempt = attempt == null || attempt < 1 ? 1 : attempt;
    }

    public void execute(QueueableContext context) {
        List<Id> current = new List<Id>();
        List<Id> remaining = new List<Id>();
        for (Integer i = 0; i < orderIds.size(); i++) {
            if (i < CHUNK_SIZE) current.add(orderIds[i]); else remaining.add(orderIds[i]);
        }
        processAttempt(current, attempt);
        if (!remaining.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new ProcurementDispatchQueueable(remaining, attempt));
        }
    }

    // One dispatch attempt for a set of orders. All callouts run first and DML afterwards, as required for
    // Queueable jobs that allow callouts. An order becomes Sent only when the supplier confirmed it.
    public static void processAttempt(List<Id> ids, Integer attempt) {
        ProcurementConfig.Settings config = ProcurementConfig.get();
        List<Purchase_Order__c> orders = [
            SELECT Id, Name, OwnerId, Status__c, Supplier__r.Name, Order_Date__c, Expected_Delivery__c, Total_Amount__c,
                   Idempotency_Key__c, External_Order_Id__c, Last_Sync_Status__c,
                   (SELECT Product__r.Name, Quantity_Ordered__c, Unit_Price__c FROM Purchase_Order_Lines__r
                    WHERE Line_Status__c != 'Cancelled')
            FROM Purchase_Order__c WHERE Id IN :ids
        ];

        Map<Id, ExternalOrderClient.OrderResponse> responses = new Map<Id, ExternalOrderClient.OrderResponse>();
        Map<Id, String> keys = new Map<Id, String>();
        for (Purchase_Order__c po : orders) {
            // Already confirmed, cancelled, or no longer awaiting dispatch: nothing to send (idempotent re-run).
            if (po.Status__c != 'Approved' || String.isNotBlank(po.External_Order_Id__c) || po.Last_Sync_Status__c != 'Pending') {
                continue;
            }
            if (String.isBlank(po.Idempotency_Key__c)) po.Idempotency_Key__c = 'PO-' + po.Id;
            keys.put(po.Id, po.Idempotency_Key__c);
            responses.put(po.Id, ExternalOrderClient.submitOrder(po));
        }
        if (responses.isEmpty()) return;

        // Re-check under lock: a concurrent job may have confirmed the order while the callout was running.
        Map<Id, Purchase_Order__c> locked = new Map<Id, Purchase_Order__c>([
            SELECT Id, Status__c, External_Order_Id__c FROM Purchase_Order__c WHERE Id IN :responses.keySet() FOR UPDATE
        ]);
        Map<Id, Purchase_Order__c> ordersById = new Map<Id, Purchase_Order__c>(orders);

        List<Purchase_Order__c> updates = new List<Purchase_Order__c>();
        List<Id> retryIds = new List<Id>();
        List<Purchase_Order__c> finalFailures = new List<Purchase_Order__c>();
        Map<Id, String> failureMessages = new Map<Id, String>();

        for (Id orderId : responses.keySet()) {
            Purchase_Order__c current = locked.get(orderId);
            if (current == null || current.Status__c != 'Approved' || String.isNotBlank(current.External_Order_Id__c)) continue;
            ExternalOrderClient.OrderResponse response = responses.get(orderId);
            Purchase_Order__c change = new Purchase_Order__c(
                Id = orderId, Idempotency_Key__c = keys.get(orderId), Dispatch_Attempts__c = attempt
            );
            if (response.success) {
                change.Status__c = 'Sent';
                change.Sent_At__c = Datetime.now();
                change.External_Order_Id__c = response.externalOrderId;
                change.Last_Sync_Status__c = 'Success';
                change.Last_Sync_Error__c = null;
            } else {
                change.Last_Sync_Error__c = truncate(response.message);
                if (response.retryable && attempt < config.maxDispatchAttempts) {
                    change.Last_Sync_Status__c = 'Pending';
                    retryIds.add(orderId);
                } else {
                    change.Last_Sync_Status__c = 'Failed';
                    finalFailures.add(ordersById.get(orderId));
                    failureMessages.put(orderId, response.message);
                }
            }
            updates.add(change);
        }

        saveOutcomes(updates, ordersById, finalFailures, failureMessages);

        if (!retryIds.isEmpty()) IntegrationRetryQueueable.scheduleRetry(retryIds, attempt);
        if (!finalFailures.isEmpty()) notifyBuyers(finalFailures, failureMessages);
    }

    private static void saveOutcomes(
        List<Purchase_Order__c> updates, Map<Id, Purchase_Order__c> ordersById,
        List<Purchase_Order__c> finalFailures, Map<Id, String> failureMessages
    ) {
        PurchaseOrderService.dispatchConfirmationInProgress = true;
        List<Database.SaveResult> saved;
        try {
            saved = Database.update(updates, false);
        } finally {
            PurchaseOrderService.dispatchConfirmationInProgress = false;
        }

        // The supplier already confirmed these orders, so a save failure must be recorded, not lost.
        List<Purchase_Order__c> recovery = new List<Purchase_Order__c>();
        for (Integer i = 0; i < saved.size(); i++) {
            if (saved[i].isSuccess()) continue;
            Purchase_Order__c failedUpdate = updates[i];
            String message = failedUpdate.Status__c == 'Sent'
                ? 'The supplier confirmed order ' + failedUpdate.External_Order_Id__c + ' but it could not be saved: ' + saved[i].getErrors()[0].getMessage()
                : 'The dispatch result could not be saved: ' + saved[i].getErrors()[0].getMessage();
            recovery.add(new Purchase_Order__c(
                Id = failedUpdate.Id, Last_Sync_Status__c = 'Failed', Last_Sync_Error__c = truncate(message),
                Dispatch_Attempts__c = failedUpdate.Dispatch_Attempts__c
            ));
            if (!failureMessages.containsKey(failedUpdate.Id)) {
                finalFailures.add(ordersById.get(failedUpdate.Id));
                failureMessages.put(failedUpdate.Id, message);
            }
        }
        if (!recovery.isEmpty()) Database.update(recovery, false);
    }

    // Final failures are tracked on the order (Last_Sync_Error__c), as a follow-up task for the buyer and
    // as an in-app notification. Task creation is bulk; an open task for the same order is not duplicated.
    private static void notifyBuyers(List<Purchase_Order__c> failures, Map<Id, String> messages) {
        Set<Id> failedIds = new Map<Id, Purchase_Order__c>(failures).keySet();
        Set<Id> alreadyTasked = new Set<Id>();
        for (Task existing : [
            SELECT WhatId FROM Task WHERE WhatId IN :failedIds AND IsClosed = false AND Subject LIKE 'Purchase order dispatch failed:%'
        ]) {
            alreadyTasked.add(existing.WhatId);
        }
        List<Task> tasks = new List<Task>();
        for (Purchase_Order__c po : failures) {
            if (alreadyTasked.contains(po.Id)) continue;
            tasks.add(new Task(
                Subject = 'Purchase order dispatch failed: ' + po.Name,
                Description = messages.get(po.Id) + ' The order is still Approved. Resolve the issue and dispatch it again.',
                WhatId = po.Id,
                OwnerId = po.OwnerId,
                ActivityDate = Date.today().addDays(1),
                Priority = 'High',
                Status = 'Not Started'
            ));
        }
        if (!tasks.isEmpty()) Database.insert(tasks, false);

        List<CustomNotificationType> types = [SELECT Id FROM CustomNotificationType WHERE DeveloperName = 'Procurement_Alert' LIMIT 1];
        if (types.isEmpty()) return;
        for (Purchase_Order__c po : failures) {
            try {
                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                notification.setNotificationTypeId(types[0].Id);
                notification.setTargetId(po.Id);
                notification.setTitle('Purchase order dispatch failed: ' + po.Name);
                notification.setBody(truncate(messages.get(po.Id)));
                notification.send(new Set<String>{ String.valueOf(po.OwnerId) });
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Dispatch failure notification skipped: ' + e.getMessage());
            }
        }
    }

    private static String truncate(String message) {
        if (message == null) return null;
        return message.length() > MAX_ERROR_LENGTH ? message.substring(0, MAX_ERROR_LENGTH) : message;
    }
}
