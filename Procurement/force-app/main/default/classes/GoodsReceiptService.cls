public with sharing class GoodsReceiptService {

    public class GoodsReceiptException extends Exception {}

    private static final Set<String> RECEIVABLE_PO_STATUSES = new Set<String>{
        'Approved', 'Sent', 'Acknowledged', 'Partially Received'
    };

    @TestVisible private static Boolean simulateFailureAfterStockUpdate = false;

    // ---------------------------------------------------------------- Flow entry point

    public class PostReceiptInput {
        @InvocableVariable(label='Receipt Id' required=true)
        public String receiptId;
    }

    public class PostReceiptResult {
        @InvocableVariable(label='Receipt Id')
        public String receiptId;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Message')
        public String message;
        @InvocableVariable(label='Lines Posted')
        public Integer linesPosted;
        @InvocableVariable(label='Units Accepted')
        public Decimal unitsAccepted;
        @InvocableVariable(label='Purchase Order Status')
        public String purchaseOrderStatus;
    }

    @InvocableMethod(
        label='Post Goods Receipt'
        description='Atomically posts a goods receipt: updates stock, creates inventory transactions, updates purchase order lines and status, and marks the receipt Posted. Rolls everything back and returns the error message on failure.'
    )
    public static List<PostReceiptResult> postGoodsReceiptFromFlow(List<PostReceiptInput> inputs) {
        List<PostReceiptResult> results = new List<PostReceiptResult>();
        for (PostReceiptInput input : inputs) {
            PostReceiptResult result = new PostReceiptResult();
            result.receiptId = input.receiptId;
            try {
                if (String.isBlank(input.receiptId)) {
                    throw new GoodsReceiptException('A goods receipt Id is required.');
                }
                PostReceiptResult posted = postReceiptCore(Id.valueOf(input.receiptId));
                result = posted;
                result.isSuccess = true;
                result.message = 'Goods receipt posted successfully.';
            } catch (Exception e) {
                result.isSuccess = false;
                result.message = e.getMessage();
            }
            results.add(result);
        }
        return results;
    }

    // ---------------------------------------------------------------- Posting core

    // One savepoint covers every DML below, so stock, transactions, PO updates and
    // the receipt status either all commit or all roll back.
    private static PostReceiptResult postReceiptCore(Id receiptId) {
        if (!Schema.sObjectType.Goods_Receipt__c.isUpdateable()) {
            throw new GoodsReceiptException('You do not have permission to post goods receipts.');
        }
        Savepoint sp = Database.setSavepoint();
        try {
            List<Goods_Receipt__c> locked = [
                SELECT Id, Status__c, Purchase_Order__c, Warehouse__c, Received_By__c
                FROM Goods_Receipt__c WHERE Id = :receiptId FOR UPDATE
            ];
            if (locked.isEmpty()) {
                throw new GoodsReceiptException('Goods receipt not found or not accessible.');
            }
            Goods_Receipt__c receipt = locked[0];
            if (receipt.Status__c == 'Posted') {
                throw new GoodsReceiptException('This receipt has already been posted.');
            }
            if (receipt.Status__c == 'Rejected') {
                throw new GoodsReceiptException('Cannot post a rejected receipt.');
            }
            if (receipt.Purchase_Order__c == null) {
                throw new GoodsReceiptException('The receipt is not linked to a purchase order.');
            }

            Purchase_Order__c po = [
                SELECT Id, Status__c, Warehouse__c
                FROM Purchase_Order__c WHERE Id = :receipt.Purchase_Order__c WITH USER_MODE
            ];
            if (!RECEIVABLE_PO_STATUSES.contains(po.Status__c)) {
                throw new GoodsReceiptException('Goods cannot be received against a purchase order with status: ' + po.Status__c);
            }
            Id warehouseId = receipt.Warehouse__c != null ? receipt.Warehouse__c : po.Warehouse__c;
            if (warehouseId == null) {
                throw new GoodsReceiptException('No warehouse is defined on the receipt or its purchase order.');
            }

            List<Goods_Receipt_Line__c> receiptLines = [
                SELECT Id, Purchase_Order_Line__c, Quantity_Delivered__c, Quantity_Accepted__c,
                       Quantity_Rejected__c, Rejection_Reason__c
                FROM Goods_Receipt_Line__c WHERE Goods_Receipt__c = :receiptId WITH USER_MODE
            ];
            if (receiptLines.isEmpty()) {
                throw new GoodsReceiptException('The receipt has no lines to post.');
            }

            Set<Id> polIds = new Set<Id>();
            for (Goods_Receipt_Line__c grl : receiptLines) {
                if (grl.Purchase_Order_Line__c == null) {
                    throw new GoodsReceiptException('Every receipt line must reference a purchase order line.');
                }
                polIds.add(grl.Purchase_Order_Line__c);
            }
            Map<Id, Purchase_Order_Line__c> polMap = new Map<Id, Purchase_Order_Line__c>([
                SELECT Id, Product__c, Product__r.Name, Purchase_Order__c, Quantity_Ordered__c,
                       Quantity_Received__c, Quantity_Rejected__c, Line_Status__c
                FROM Purchase_Order_Line__c WHERE Id IN :polIds WITH USER_MODE
            ]);

            Map<Id, Decimal> acceptedByPol = new Map<Id, Decimal>();
            Boolean anyDelivered = false;
            for (Goods_Receipt_Line__c grl : receiptLines) {
                Purchase_Order_Line__c pol = polMap.get(grl.Purchase_Order_Line__c);
                if (pol == null || pol.Purchase_Order__c != po.Id) {
                    throw new GoodsReceiptException('A receipt line references a purchase order line that does not belong to this purchase order.');
                }
                String lineError = validateLineQuantities(grl);
                if (lineError != null) {
                    throw new GoodsReceiptException(lineError);
                }
                Decimal accepted = nz(grl.Quantity_Accepted__c);
                if (nz(grl.Quantity_Delivered__c) > 0) anyDelivered = true;
                Decimal runningAccepted = nz(acceptedByPol.get(pol.Id)) + accepted;
                acceptedByPol.put(pol.Id, runningAccepted);
                Decimal outstanding = nz(pol.Quantity_Ordered__c) - nz(pol.Quantity_Received__c);
                if (runningAccepted > outstanding) {
                    throw new GoodsReceiptException(
                        'Accepted quantity (' + runningAccepted + ') exceeds the outstanding quantity (' + outstanding +
                        ') for product ' + pol.Product__r.Name + '.'
                    );
                }
            }
            if (!anyDelivered) {
                throw new GoodsReceiptException('At least one receipt line must have a delivered quantity.');
            }

            Set<String> txKeys = new Set<String>();
            for (Goods_Receipt_Line__c grl : receiptLines) {
                txKeys.add(receiptId + '-' + grl.Id);
            }
            if (![SELECT Id FROM Inventory_Transaction__c WHERE Transaction_Key__c IN :txKeys LIMIT 1].isEmpty()) {
                throw new GoodsReceiptException('This receipt has already been posted.');
            }

            Set<Id> productIds = new Set<Id>();
            for (Purchase_Order_Line__c pol : polMap.values()) {
                if (pol.Product__c != null) productIds.add(pol.Product__c);
            }
            Map<Id, Inventory__c> invByProduct = new Map<Id, Inventory__c>();
            for (Inventory__c inv : [
                SELECT Id, Product__c, On_Hand__c, On_Order__c
                FROM Inventory__c WHERE Product__c IN :productIds AND Warehouse__c = :warehouseId
                FOR UPDATE
            ]) {
                invByProduct.put(inv.Product__c, inv);
            }

            Map<Id, Decimal> runningOnHand = new Map<Id, Decimal>();
            List<Inventory_Transaction__c> txToInsert = new List<Inventory_Transaction__c>();
            Map<Id, Purchase_Order_Line__c> polToUpdate = new Map<Id, Purchase_Order_Line__c>();
            Decimal unitsAccepted = 0;

            for (Goods_Receipt_Line__c grl : receiptLines) {
                Purchase_Order_Line__c pol = polMap.get(grl.Purchase_Order_Line__c);
                Decimal accepted = nz(grl.Quantity_Accepted__c);
                Decimal rejected = nz(grl.Quantity_Rejected__c);
                unitsAccepted += accepted;

                if (accepted > 0) {
                    Inventory__c inv = invByProduct.get(pol.Product__c);
                    if (inv == null) {
                        throw new GoodsReceiptException('No inventory record exists for product ' + pol.Product__r.Name + ' in the receiving warehouse.');
                    }
                    Decimal before = runningOnHand.containsKey(inv.Id) ? runningOnHand.get(inv.Id) : nz(inv.On_Hand__c);
                    Decimal after = before + accepted;
                    runningOnHand.put(inv.Id, after);
                    inv.On_Hand__c = after;
                    if (inv.On_Order__c != null) inv.On_Order__c = Math.max(0, inv.On_Order__c - accepted);

                    txToInsert.add(new Inventory_Transaction__c(
                        Inventory__c = inv.Id,
                        Product__c = pol.Product__c,
                        Warehouse__c = warehouseId,
                        Transaction_Type__c = 'Receipt',
                        Quantity_Change__c = accepted,
                        Quantity_Before__c = before,
                        Quantity_After__c = after,
                        Source_Receipt_Line__c = grl.Id,
                        Source_Order_Line__c = pol.Id,
                        Transaction_Key__c = receiptId + '-' + grl.Id,
                        Processed_At__c = Datetime.now(),
                        Processed_By__c = UserInfo.getUserId()
                    ));
                }

                pol.Quantity_Received__c = nz(pol.Quantity_Received__c) + accepted;
                pol.Quantity_Rejected__c = nz(pol.Quantity_Rejected__c) + rejected;
                pol.Line_Status__c = nz(pol.Quantity_Received__c) >= nz(pol.Quantity_Ordered__c) ? 'Complete'
                    : (pol.Quantity_Received__c > 0 ? 'Partially Received' : pol.Line_Status__c);
                polToUpdate.put(pol.Id, pol);
            }

            // Derived stock records are system-maintained; the caller was already authorised to post above.
            if (!runningOnHand.isEmpty()) {
                List<Inventory__c> invToUpdate = new List<Inventory__c>();
                for (Inventory__c inv : invByProduct.values()) {
                    if (runningOnHand.containsKey(inv.Id)) invToUpdate.add(inv);
                }
                update invToUpdate;
            }
            if (!txToInsert.isEmpty()) insert txToInsert;
            update polToUpdate.values();

            if (simulateFailureAfterStockUpdate && Test.isRunningTest()) {
                throw new GoodsReceiptException('Simulated failure after stock update.');
            }

            String poStatus = recalculatePurchaseOrderStatus(po);

            receipt.Status__c = 'Posted';
            receipt.Posted_At__c = Datetime.now();
            if (receipt.Warehouse__c == null) receipt.Warehouse__c = warehouseId;
            if (receipt.Received_By__c == null) receipt.Received_By__c = UserInfo.getUserId();
            update receipt;

            PostReceiptResult result = new PostReceiptResult();
            result.receiptId = receiptId;
            result.linesPosted = receiptLines.size();
            result.unitsAccepted = unitsAccepted;
            result.purchaseOrderStatus = poStatus;
            return result;
        } catch (Exception e) {
            Database.rollback(sp);
            if (e instanceof GoodsReceiptException) throw e;
            throw new GoodsReceiptException('Error posting receipt: ' + e.getMessage());
        }
    }

    private static String recalculatePurchaseOrderStatus(Purchase_Order__c po) {
        List<Purchase_Order_Line__c> lines = [
            SELECT Id, Line_Status__c, Quantity_Received__c
            FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :po.Id AND Line_Status__c != 'Cancelled'
        ];
        if (lines.isEmpty()) return po.Status__c;
        Boolean allComplete = true;
        Boolean anyReceived = false;
        for (Purchase_Order_Line__c line : lines) {
            if (line.Line_Status__c != 'Complete') allComplete = false;
            if (nz(line.Quantity_Received__c) > 0) anyReceived = true;
        }
        String newStatus = allComplete ? 'Received' : (anyReceived ? 'Partially Received' : po.Status__c);
        if (newStatus != po.Status__c) {
            update new Purchase_Order__c(Id = po.Id, Status__c = newStatus);
        }
        return newStatus;
    }

    // Returns an error message, or null when the line quantities are valid.
    private static String validateLineQuantities(Goods_Receipt_Line__c line) {
        Decimal delivered = nz(line.Quantity_Delivered__c);
        Decimal accepted = nz(line.Quantity_Accepted__c);
        Decimal rejected = nz(line.Quantity_Rejected__c);
        if (delivered < 0 || accepted < 0 || rejected < 0) {
            return 'Quantities cannot be negative.';
        }
        if (accepted + rejected > delivered) {
            return 'Accepted plus rejected quantity cannot exceed the delivered quantity.';
        }
        if (rejected > 0 && String.isBlank(line.Rejection_Reason__c)) {
            return 'A rejection reason is required when a rejected quantity is entered.';
        }
        return null;
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }

    // ---------------------------------------------------------------- LWC / Aura entry points

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
                d.quantityOrdered = nz(pol.Quantity_Ordered__c);
                d.quantityReceived = nz(pol.Quantity_Received__c);
                d.remaining = d.quantityOrdered - d.quantityReceived;
                d.lineStatus = pol.Line_Status__c;
                result.lines.add(d);
            }
            return result;
        } catch (Exception e) {
            throw auraError('Error loading PO for receipt: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Id saveGoodsReceipt(String receiptJson, String linesJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            Goods_Receipt__c receipt = (Goods_Receipt__c) JSON.deserialize(receiptJson, Goods_Receipt__c.class);
            List<Goods_Receipt_Line__c> lines = (List<Goods_Receipt_Line__c>) JSON.deserialize(linesJson, List<Goods_Receipt_Line__c>.class);

            for (Goods_Receipt_Line__c line : lines) {
                String lineError = validateLineQuantities(line);
                if (lineError != null) throw auraError(lineError);
            }

            if (receipt.Warehouse__c == null && receipt.Purchase_Order__c != null) {
                List<Purchase_Order__c> pos = [SELECT Warehouse__c FROM Purchase_Order__c WHERE Id = :receipt.Purchase_Order__c];
                if (!pos.isEmpty()) receipt.Warehouse__c = pos[0].Warehouse__c;
            }

            if (receipt.Id == null) {
                if (String.isBlank(receipt.Status__c)) receipt.Status__c = 'Draft';
                if (receipt.Receipt_Date__c == null) receipt.Receipt_Date__c = Date.today();
                if (receipt.Received_By__c == null) receipt.Received_By__c = UserInfo.getUserId();
                insert receipt;
            } else {
                Goods_Receipt__c existing = [SELECT Status__c FROM Goods_Receipt__c WHERE Id = :receipt.Id LIMIT 1];
                if (existing.Status__c == 'Posted') {
                    throw auraError('Cannot edit a posted goods receipt.');
                }
                update receipt;
            }

            Set<Id> incomingIds = new Set<Id>();
            for (Goods_Receipt_Line__c l : lines) { if (l.Id != null) incomingIds.add(l.Id); }
            List<Goods_Receipt_Line__c> existingLines = [SELECT Id FROM Goods_Receipt_Line__c WHERE Goods_Receipt__c = :receipt.Id];
            List<Goods_Receipt_Line__c> toDelete = new List<Goods_Receipt_Line__c>();
            for (Goods_Receipt_Line__c el : existingLines) {
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
            throw auraError('Error saving goods receipt: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void postGoodsReceipt(Id receiptId) {
        try {
            postReceiptCore(receiptId);
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Goods_Receipt__c> getRecentReceipts(Integer limitCount) {
        try {
            Integer lim = (limitCount != null && limitCount > 0) ? limitCount : 20;
            return [SELECT Id, Name, Status__c, Purchase_Order__r.Name, Warehouse__r.Name,
                           Receipt_Date__c, Received_By__r.Name
                    FROM Goods_Receipt__c ORDER BY CreatedDate DESC LIMIT :lim];
        } catch (Exception e) {
            throw auraError('Error loading receipts: ' + e.getMessage());
        }
    }
}
