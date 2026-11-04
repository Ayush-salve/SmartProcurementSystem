public with sharing class GoodsReceiptService {

    public class PurchaseOrderLineDetail {
        @AuraEnabled public Id polId;
        @AuraEnabled public String productName;
        @AuraEnabled public Id productId;
        @AuraEnabled public Decimal quantityOrdered;
        @AuraEnabled public Decimal quantityReceived;
        @AuraEnabled public Decimal remaining;
        @AuraEnabled public String lineStatus;
    }

    public class PoForReceipt {
        @AuraEnabled public Purchase_Order__c po;
        @AuraEnabled public List<PurchaseOrderLineDetail> lines;
    }

    @AuraEnabled(cacheable=true)
    public static PoForReceipt getPurchaseOrderForReceipt(Id poId) {
        try {
            Purchase_Order__c po = [
                SELECT Id, Name, Status__c, Supplier__c, Supplier__r.Name,
                       Warehouse__c, Warehouse__r.Name, Order_Date__c, Expected_Delivery__c
                FROM Purchase_Order__c WHERE Id = :poId LIMIT 1
            ];
            List<Purchase_Order_Line__c> polList = [
                SELECT Id, Product__c, Product__r.Name, Quantity_Ordered__c, Quantity_Received__c, Line_Status__c
                FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :poId AND Line_Status__c != 'Cancelled'
                ORDER BY Name
            ];
            PoForReceipt result = new PoForReceipt();
            result.po = po;
            result.lines = new List<PurchaseOrderLineDetail>();
            for (Purchase_Order_Line__c pol : polList) {
                PurchaseOrderLineDetail d = new PurchaseOrderLineDetail();
                d.polId = pol.Id;
                d.productId = pol.Product__c;
                d.productName = pol.Product__r != null ? pol.Product__r.Name : '';
                d.quantityOrdered = pol.Quantity_Ordered__c != null ? pol.Quantity_Ordered__c : 0;
                d.quantityReceived = pol.Quantity_Received__c != null ? pol.Quantity_Received__c : 0;
                d.remaining = d.quantityOrdered - d.quantityReceived;
                d.lineStatus = pol.Line_Status__c;
                result.lines.add(d);
            }
            return result;
        } catch (Exception e) {
            throw new AuraHandledException('Error loading PO for receipt: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Id saveGoodsReceipt(String receiptJson, String linesJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            Goods_Receipt__c receipt = (Goods_Receipt__c) JSON.deserialize(receiptJson, Goods_Receipt__c.class);
            List<Goods_Receipt_Line__c> lines = (List<Goods_Receipt_Line__c>) JSON.deserialize(linesJson, List<Goods_Receipt_Line__c>.class);

            if (receipt.Id == null) {
                if (String.isBlank(receipt.Status__c)) receipt.Status__c = 'Draft';
                if (receipt.Receipt_Date__c == null) receipt.Receipt_Date__c = Date.today();
                if (receipt.Received_By__c == null) receipt.Received_By__c = UserInfo.getUserId();
                insert receipt;
            } else {
                Goods_Receipt__c existing = [SELECT Status__c FROM Goods_Receipt__c WHERE Id = :receipt.Id LIMIT 1];
                if (existing.Status__c == 'Posted') {
                    throw new AuraHandledException('Cannot edit a posted goods receipt.');
                }
                update receipt;
            }

            Set<Id> incomingIds = new Set<Id>();
            for (Goods_Receipt_Line__c l : lines) { if (l.Id != null) incomingIds.add(l.Id); }
            List<Goods_Receipt_Line__c> existing = [SELECT Id FROM Goods_Receipt_Line__c WHERE Goods_Receipt__c = :receipt.Id];
            List<Goods_Receipt_Line__c> toDelete = new List<Goods_Receipt_Line__c>();
            for (Goods_Receipt_Line__c el : existing) {
                if (!incomingIds.contains(el.Id)) toDelete.add(el);
            }
            if (!toDelete.isEmpty()) delete toDelete;

            List<Goods_Receipt_Line__c> toInsert = new List<Goods_Receipt_Line__c>();
            List<Goods_Receipt_Line__c> toUpdate = new List<Goods_Receipt_Line__c>();
            for (Goods_Receipt_Line__c line : lines) {
                line.Goods_Receipt__c = receipt.Id;
                if (line.Id == null) { toInsert.add(line); } else { toUpdate.add(line); }
            }
            if (!toInsert.isEmpty()) insert toInsert;
            if (!toUpdate.isEmpty()) update toUpdate;

            return receipt.Id;
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Error saving goods receipt: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void postGoodsReceipt(Id receiptId) {
        Savepoint sp = Database.setSavepoint();
        try {
            Goods_Receipt__c receipt = [
                SELECT Id, Status__c, Purchase_Order__c, Warehouse__c,
                    (SELECT Id, Purchase_Order_Line__c, Quantity_Accepted__c, Quantity_Rejected__c, Quantity_Delivered__c
                     FROM Goods_Receipt_Lines__r)
                FROM Goods_Receipt__c WHERE Id = :receiptId FOR UPDATE
            ];

            if (receipt.Status__c == 'Posted') {
                throw new AuraHandledException('This receipt has already been posted.');
            }
            if (receipt.Status__c == 'Rejected') {
                throw new AuraHandledException('Cannot post a rejected receipt.');
            }

            Set<Id> polIds = new Set<Id>();
            for (Goods_Receipt_Line__c grl : receipt.Goods_Receipt_Lines__r) {
                if (grl.Purchase_Order_Line__c != null) polIds.add(grl.Purchase_Order_Line__c);
            }

            Map<Id, Purchase_Order_Line__c> polMap = new Map<Id, Purchase_Order_Line__c>();
            if (!polIds.isEmpty()) {
                for (Purchase_Order_Line__c pol : [
                    SELECT Id, Product__c, Quantity_Ordered__c, Quantity_Received__c, Line_Status__c, Purchase_Order__c
                    FROM Purchase_Order_Line__c WHERE Id IN :polIds
                ]) {
                    polMap.put(pol.Id, pol);
                }
            }

            Set<Id> productIds = new Set<Id>();
            for (Purchase_Order_Line__c pol : polMap.values()) {
                if (pol.Product__c != null) productIds.add(pol.Product__c);
            }

            Map<Id, Inventory__c> invByProduct = new Map<Id, Inventory__c>();
            if (!productIds.isEmpty() && receipt.Warehouse__c != null) {
                for (Inventory__c inv : [
                    SELECT Id, Product__c, Warehouse__c, On_Hand__c, On_Order__c
                    FROM Inventory__c WHERE Product__c IN :productIds AND Warehouse__c = :receipt.Warehouse__c
                ]) {
                    invByProduct.put(inv.Product__c, inv);
                }
            }

            List<Inventory__c> invToUpdate = new List<Inventory__c>();
            List<Inventory_Transaction__c> txToInsert = new List<Inventory_Transaction__c>();
            List<Purchase_Order_Line__c> polToUpdate = new List<Purchase_Order_Line__c>();
            Set<Id> processedInvIds = new Set<Id>();

            for (Goods_Receipt_Line__c grl : receipt.Goods_Receipt_Lines__r) {
                if (grl.Purchase_Order_Line__c == null) continue;
                Decimal accepted = grl.Quantity_Accepted__c != null ? grl.Quantity_Accepted__c : 0;
                if (accepted <= 0) continue;

                Purchase_Order_Line__c pol = polMap.get(grl.Purchase_Order_Line__c);
                if (pol == null) continue;

                Inventory__c inv = invByProduct.get(pol.Product__c);
                if (inv != null && !processedInvIds.contains(inv.Id)) {
                    Decimal qtyBefore = inv.On_Hand__c != null ? inv.On_Hand__c : 0;
                    inv.On_Hand__c = qtyBefore + accepted;
                    if (inv.On_Order__c != null) inv.On_Order__c = Math.max(0, inv.On_Order__c - accepted);
                    invToUpdate.add(inv);
                    processedInvIds.add(inv.Id);

                    txToInsert.add(new Inventory_Transaction__c(
                        Inventory__c = inv.Id,
                        Product__c = pol.Product__c,
                        Warehouse__c = receipt.Warehouse__c,
                        Transaction_Type__c = 'Receipt',
                        Quantity_Change__c = accepted,
                        Quantity_Before__c = qtyBefore,
                        Quantity_After__c = qtyBefore + accepted,
                        Source_Receipt_Line__c = grl.Id,
                        Source_Order_Line__c = grl.Purchase_Order_Line__c,
                        Transaction_Key__c = receiptId + '-' + grl.Id,
                        Processed_At__c = Datetime.now(),
                        Processed_By__c = UserInfo.getUserId()
                    ));
                }

                Decimal prevReceived = pol.Quantity_Received__c != null ? pol.Quantity_Received__c : 0;
                pol.Quantity_Received__c = prevReceived + accepted;
                pol.Line_Status__c = pol.Quantity_Received__c >= pol.Quantity_Ordered__c ? 'Complete' : 'Partially Received';
                polToUpdate.add(pol);
            }

            if (!invToUpdate.isEmpty()) update invToUpdate;
            if (!txToInsert.isEmpty()) insert txToInsert;
            if (!polToUpdate.isEmpty()) update polToUpdate;

            receipt.Status__c = 'Posted';
            receipt.Posted_At__c = Datetime.now();
            update receipt;

            if (!polMap.isEmpty()) {
                Id poId = polMap.values()[0].Purchase_Order__c;
                updatePoStatusAfterPosting(poId);
            }

        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Error posting receipt: ' + e.getMessage());
        }
    }

    private static void updatePoStatusAfterPosting(Id poId) {
        List<Purchase_Order_Line__c> lines = [
            SELECT Id, Line_Status__c
            FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :poId AND Line_Status__c != 'Cancelled'
        ];
        if (lines.isEmpty()) return;
        Integer total = lines.size();
        Integer complete = 0;
        for (Purchase_Order_Line__c l : lines) { if (l.Line_Status__c == 'Complete') complete++; }
        Purchase_Order__c po = new Purchase_Order__c(Id = poId);
        if (complete == total) { po.Status__c = 'Received'; }
        else if (complete > 0) { po.Status__c = 'Partially Received'; }
        else { return; }
        update po;
    }

    @AuraEnabled(cacheable=true)
    public static List<Goods_Receipt__c> getRecentReceipts(Integer limitCount) {
        try {
            Integer lim = (limitCount != null && limitCount > 0) ? limitCount : 20;
            return [SELECT Id, Name, Status__c, Purchase_Order__r.Name, Warehouse__r.Name,
                           Receipt_Date__c, Received_By__r.Name
                    FROM Goods_Receipt__c ORDER BY CreatedDate DESC LIMIT :lim];
        } catch (Exception e) {
            throw new AuraHandledException('Error loading receipts: ' + e.getMessage());
        }
    }
}
