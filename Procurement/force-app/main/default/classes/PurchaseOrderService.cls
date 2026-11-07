public with sharing class PurchaseOrderService {

    public class PurchaseOrderWrapper {
        @AuraEnabled public Purchase_Order__c order;
        @AuraEnabled public List<Purchase_Order_Line__c> lines;
        @AuraEnabled public Boolean isEditable;
        @AuraEnabled public Boolean canDispatch;
    }

    private static final Set<String> EDITABLE_STATUSES = new Set<String>{'Draft', 'Pending Approval'};
    private static final Set<String> DISPATCHABLE_STATUSES = new Set<String>{'Approved'};

    public static final String OP_PREPARE_APPROVAL = 'PREPARE_APPROVAL';
    public static final String OP_DISPATCH = 'DISPATCH';

    public class OrderRequest {
        @InvocableVariable(label='Purchase Order Id' required=true)
        public Id purchaseOrderId;
        @InvocableVariable(label='Operation (PREPARE_APPROVAL or DISPATCH)' required=true)
        public String operation;
        @InvocableVariable(label='Prior Status')
        public String priorStatus;
    }

    public class OrderResult {
        @InvocableVariable(label='Purchase Order Id')
        public Id purchaseOrderId;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Message')
        public String message;
        @InvocableVariable(label='Total Amount')
        public Decimal totalAmount;
    }

    // PREPARE_APPROVAL validates the order and recalculates Subtotal from its lines so approval routing
    // uses an authoritative amount. DISPATCH validates an approved order and queues the external dispatch.
    @InvocableMethod(
        label='Process Purchase Order'
        description='Validates purchase orders for approval or dispatch. Returns a result per order instead of throwing; dispatch is performed asynchronously.'
    )
    public static List<OrderResult> processFromFlow(List<OrderRequest> requests) {
        Set<Id> ids = new Set<Id>();
        for (OrderRequest r : requests) {
            if (r.purchaseOrderId != null) ids.add(r.purchaseOrderId);
        }
        Map<Id, Purchase_Order__c> poMap = new Map<Id, Purchase_Order__c>([
            SELECT Id, Status__c, Supplier__c, Subtotal__c, Tax_Amount__c, Shipping_Amount__c,
                   External_Order_Id__c, Idempotency_Key__c,
                   (SELECT Id, Product__c, Quantity_Ordered__c, Unit_Price__c, Line_Total__c, Line_Status__c
                    FROM Purchase_Order_Lines__r WHERE Line_Status__c != 'Cancelled')
            FROM Purchase_Order__c WHERE Id IN :ids WITH USER_MODE
        ]);

        List<OrderResult> results = new List<OrderResult>();
        Map<Id, Purchase_Order__c> toUpdate = new Map<Id, Purchase_Order__c>();
        List<Id> toDispatch = new List<Id>();

        for (OrderRequest r : requests) {
            OrderResult res = new OrderResult();
            res.purchaseOrderId = r.purchaseOrderId;
            res.isSuccess = false;
            Purchase_Order__c po = poMap.get(r.purchaseOrderId);
            if (po == null) {
                res.message = 'Purchase order not found or not accessible.';
                results.add(res);
                continue;
            }
            Decimal subtotal = 0;
            for (Purchase_Order_Line__c line : po.Purchase_Order_Lines__r) {
                subtotal += line.Line_Total__c == null ? 0 : line.Line_Total__c;
            }
            res.totalAmount = subtotal + nz(po.Tax_Amount__c) + nz(po.Shipping_Amount__c);

            String error = validateOrderContent(po);
            if (error == null && r.operation == OP_DISPATCH) {
                error = validateDispatch(po, r.priorStatus);
            } else if (error == null && r.operation != OP_PREPARE_APPROVAL) {
                error = 'Unsupported operation: ' + r.operation;
            }

            if (error != null) {
                res.message = error;
            } else {
                res.isSuccess = true;
                res.message = 'Validation passed.';
                Purchase_Order__c upd = toUpdate.containsKey(po.Id) ? toUpdate.get(po.Id) : new Purchase_Order__c(Id = po.Id);
                if (po.Subtotal__c != subtotal) upd.Subtotal__c = subtotal;
                if (r.operation == OP_DISPATCH) {
                    if (String.isBlank(po.Idempotency_Key__c)) upd.Idempotency_Key__c = 'PO-' + po.Id;
                    upd.Last_Sync_Status__c = 'Pending';
                    toDispatch.add(po.Id);
                    res.message = 'Dispatch queued.';
                }
                toUpdate.put(po.Id, upd);
            }
            results.add(res);
        }

        if (!toUpdate.isEmpty()) {
            // System-maintained total and integration fields; read access to the order was verified above.
            update toUpdate.values();
        }
        if (!toDispatch.isEmpty()) {
            System.enqueueJob(new PurchaseOrderDispatchJob(toDispatch));
        }
        return results;
    }

    private static String validateOrderContent(Purchase_Order__c po) {
        if (po.Supplier__c == null) {
            return 'A supplier is required on the purchase order.';
        }
        if (po.Purchase_Order_Lines__r.isEmpty()) {
            return 'The purchase order has no active lines.';
        }
        for (Purchase_Order_Line__c line : po.Purchase_Order_Lines__r) {
            if (line.Product__c == null) {
                return 'Every purchase order line must have a product.';
            }
            if (line.Quantity_Ordered__c == null || line.Quantity_Ordered__c <= 0) {
                return 'Every purchase order line must have a quantity greater than zero.';
            }
            if (line.Unit_Price__c == null || line.Unit_Price__c < 0) {
                return 'Every purchase order line must have a valid unit price.';
            }
        }
        return null;
    }

    private static String validateDispatch(Purchase_Order__c po, String priorStatus) {
        if (po.Status__c != 'Sent') {
            return 'Only a purchase order in Sent status can be dispatched. Current status: ' + po.Status__c;
        }
        if (priorStatus != 'Approved') {
            return 'Only approved purchase orders can be dispatched.';
        }
        if (String.isNotBlank(po.External_Order_Id__c)) {
            return 'This purchase order has already been dispatched.';
        }
        return null;
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    @AuraEnabled(cacheable=true)
    public static PurchaseOrderWrapper getPurchaseOrderWithLines(Id poId) {
        try {
            Purchase_Order__c po = [
                SELECT Id, Name, Status__c, Purchase_Requisition__c, Supplier__c, Supplier__r.Name,
                       Warehouse__c, Warehouse__r.Name, Order_Date__c, Expected_Delivery__c,
                       Supplier_Order_Reference__c, Subtotal__c, Tax_Amount__c, Shipping_Amount__c,
                       Total_Amount__c, Sent_At__c, Last_Sync_Status__c, External_Order_Id__c, Idempotency_Key__c
                FROM Purchase_Order__c WHERE Id = :poId LIMIT 1
            ];
            List<Purchase_Order_Line__c> lines = [
                SELECT Id, Name, Product__c, Product__r.Name, Supplier_Product__c, Supplier_Product__r.Name,
                       Quantity_Ordered__c, Quantity_Received__c, Quantity_Rejected__c,
                       Unit_Price__c, Line_Total__c, Expected_Delivery__c, Line_Status__c
                FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :poId ORDER BY Name
            ];
            PurchaseOrderWrapper w = new PurchaseOrderWrapper();
            w.order = po;
            w.lines = lines;
            w.isEditable = EDITABLE_STATUSES.contains(po.Status__c);
            w.canDispatch = DISPATCHABLE_STATUSES.contains(po.Status__c);
            return w;
        } catch (Exception e) {
            throw auraError('Error loading purchase order: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Id savePurchaseOrder(String poJson, String linesJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            Purchase_Order__c po = (Purchase_Order__c) JSON.deserialize(poJson, Purchase_Order__c.class);
            List<Purchase_Order_Line__c> lines = (List<Purchase_Order_Line__c>) JSON.deserialize(linesJson, List<Purchase_Order_Line__c>.class);

            if (po.Id == null) {
                if (String.isBlank(po.Status__c)) po.Status__c = 'Draft';
                if (po.Order_Date__c == null) po.Order_Date__c = Date.today();
                insert po;
            } else {
                Purchase_Order__c existing = [SELECT Status__c FROM Purchase_Order__c WHERE Id = :po.Id LIMIT 1];
                if (!EDITABLE_STATUSES.contains(existing.Status__c)) {
                    throw auraError('Cannot edit a purchase order with status: ' + existing.Status__c);
                }
                update po;
            }

            Set<Id> incomingIds = new Set<Id>();
            for (Purchase_Order_Line__c l : lines) { if (l.Id != null) incomingIds.add(l.Id); }
            List<Purchase_Order_Line__c> existingLines = [SELECT Id FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :po.Id];
            List<Purchase_Order_Line__c> toDelete = new List<Purchase_Order_Line__c>();
            for (Purchase_Order_Line__c el : existingLines) {
                if (!incomingIds.contains(el.Id)) toDelete.add(el);
            }
            if (!toDelete.isEmpty()) delete toDelete;

            List<Purchase_Order_Line__c> toInsert = new List<Purchase_Order_Line__c>();
            List<Purchase_Order_Line__c> toUpdate = new List<Purchase_Order_Line__c>();
            for (Purchase_Order_Line__c line : lines) {
                line.Purchase_Order__c = po.Id;
                if (line.Line_Status__c == null) line.Line_Status__c = 'Open';
                if (line.Id == null) { toInsert.add(line); } else { toUpdate.add(line); }
            }
            if (!toInsert.isEmpty()) insert toInsert;
            if (!toUpdate.isEmpty()) update toUpdate;

            return po.Id;
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw auraError('Error saving purchase order: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Id createPurchaseOrderFromRequisition(Id requisitionId, Id supplierId, Id warehouseId) {
        Savepoint sp = Database.setSavepoint();
        try {
            Purchase_Requisition__c req = [
                SELECT Id, Status__c, Destination_Warehouse__c, Estimated_Total__c
                FROM Purchase_Requisition__c WHERE Id = :requisitionId LIMIT 1
            ];
            if (req.Status__c != 'Approved') {
                throw auraError('Only approved requisitions can be converted to purchase orders.');
            }
            List<Requisition_Line__c> reqLines = [
                SELECT Id, Product__c, Requested_Qty__c, Approved_Qty__c, Estimated_Unit_Price__c,
                       Approved_Unit_Price__c, Preferred_Supplier_Product__c
                FROM Requisition_Line__c WHERE Requisition__c = :requisitionId
            ];
            Purchase_Order__c po = new Purchase_Order__c(
                Purchase_Requisition__c = requisitionId,
                Supplier__c = supplierId,
                Warehouse__c = warehouseId != null ? warehouseId : req.Destination_Warehouse__c,
                Order_Date__c = Date.today(),
                Status__c = 'Draft'
            );
            insert po;

            List<Purchase_Order_Line__c> polLines = new List<Purchase_Order_Line__c>();
            for (Requisition_Line__c rl : reqLines) {
                Decimal qty = rl.Approved_Qty__c != null && rl.Approved_Qty__c > 0 ? rl.Approved_Qty__c : rl.Requested_Qty__c;
                Decimal price = rl.Approved_Unit_Price__c != null && rl.Approved_Unit_Price__c > 0 ? rl.Approved_Unit_Price__c : rl.Estimated_Unit_Price__c;
                polLines.add(new Purchase_Order_Line__c(
                    Purchase_Order__c = po.Id,
                    Product__c = rl.Product__c,
                    Supplier_Product__c = rl.Preferred_Supplier_Product__c,
                    Quantity_Ordered__c = qty,
                    Unit_Price__c = price,
                    Line_Status__c = 'Open'
                ));
            }
            if (!polLines.isEmpty()) insert polLines;

            return po.Id;
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw auraError('Error creating PO from requisition: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void dispatchPurchaseOrder(Id poId) {
        try {
            Purchase_Order__c po = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :poId LIMIT 1];
            if (!DISPATCHABLE_STATUSES.contains(po.Status__c)) {
                throw auraError('Purchase order must be Approved before dispatching. Current status: ' + po.Status__c);
            }
            po.Status__c = 'Sent';
            po.Sent_At__c = Datetime.now();
            update po;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError('Error dispatching purchase order: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Purchase_Order__c> getRecentPurchaseOrders(Integer limitCount) {
        try {
            Integer lim = (limitCount != null && limitCount > 0) ? limitCount : 20;
            return [SELECT Id, Name, Status__c, Supplier__r.Name, Warehouse__r.Name,
                           Order_Date__c, Expected_Delivery__c, Total_Amount__c
                    FROM Purchase_Order__c ORDER BY CreatedDate DESC LIMIT :lim];
        } catch (Exception e) {
            throw auraError('Error loading purchase orders: ' + e.getMessage());
        }
    }

    // AuraHandledException hides its message from callers unless setMessage is used.
    private static AuraHandledException auraError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
