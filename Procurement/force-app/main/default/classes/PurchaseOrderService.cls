public with sharing class PurchaseOrderService {

    public class PurchaseOrderWrapper {
        @AuraEnabled public Purchase_Order__c order;
        @AuraEnabled public List<Purchase_Order_Line__c> lines;
        @AuraEnabled public Boolean isEditable;
        @AuraEnabled public Boolean canDispatch;
    }

    private static final Set<String> EDITABLE_STATUSES = new Set<String>{'Draft', 'Pending Approval'};
    private static final Set<String> DISPATCHABLE_STATUSES = new Set<String>{'Approved'};

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
            throw new AuraHandledException('Error loading purchase order: ' + e.getMessage());
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
                    throw new AuraHandledException('Cannot edit a purchase order with status: ' + existing.Status__c);
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
            throw new AuraHandledException('Error saving purchase order: ' + e.getMessage());
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
                throw new AuraHandledException('Only approved requisitions can be converted to purchase orders.');
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
            throw new AuraHandledException('Error creating PO from requisition: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void dispatchPurchaseOrder(Id poId) {
        try {
            Purchase_Order__c po = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :poId LIMIT 1];
            if (!DISPATCHABLE_STATUSES.contains(po.Status__c)) {
                throw new AuraHandledException('Purchase order must be Approved before dispatching. Current status: ' + po.Status__c);
            }
            po.Status__c = 'Sent';
            po.Sent_At__c = Datetime.now();
            update po;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error dispatching purchase order: ' + e.getMessage());
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
            throw new AuraHandledException('Error loading purchase orders: ' + e.getMessage());
        }
    }
}
