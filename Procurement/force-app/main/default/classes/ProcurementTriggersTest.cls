@IsTest
private class ProcurementTriggersTest {

    @TestSetup
    static void setupData() {
        Warehouse__c wh = new Warehouse__c(Name = 'Trg WH', Warehouse_Code__c = 'TRGWH', Active__c = true);
        insert wh;
        List<Product2> products = new List<Product2>();
        for (Integer i = 0; i < 20; i++) products.add(new Product2(Name = 'Trg Product ' + i, IsActive = true));
        insert products;
        insert new Account(Name = 'Trg Supplier');
    }

    private static Warehouse__c warehouse() { return [SELECT Id FROM Warehouse__c LIMIT 1]; }
    private static List<Product2> products() { return [SELECT Id FROM Product2 ORDER BY Name]; }

    private static Purchase_Order__c createOrder(String status) {
        Purchase_Order__c po = new Purchase_Order__c(
            Supplier__c = [SELECT Id FROM Account LIMIT 1].Id, Warehouse__c = warehouse().Id,
            Order_Date__c = Date.today(), Status__c = status
        );
        insert po;
        insert new Purchase_Order_Line__c(
            Purchase_Order__c = po.Id, Product__c = products()[0].Id,
            Quantity_Ordered__c = 50, Quantity_Received__c = 0, Unit_Price__c = 10, Line_Status__c = 'Open'
        );
        return po;
    }

    private static Goods_Receipt__c createReceipt(Purchase_Order__c po, String status) {
        Goods_Receipt__c gr = new Goods_Receipt__c(
            Purchase_Order__c = po.Id, Warehouse__c = warehouse().Id, Receipt_Date__c = Date.today(),
            Status__c = status, Received_By__c = UserInfo.getUserId()
        );
        insert gr;
        return gr;
    }

    private static Goods_Receipt_Line__c receiptLine(Id receiptId, Id polId, Decimal delivered, Decimal accepted, Decimal rejected, String reason) {
        return new Goods_Receipt_Line__c(
            Goods_Receipt__c = receiptId, Purchase_Order_Line__c = polId,
            Quantity_Delivered__c = delivered, Quantity_Accepted__c = accepted,
            Quantity_Rejected__c = rejected, Rejection_Reason__c = reason
        );
    }

    private static String firstError(Database.SaveResult result) {
        System.assertEquals(false, result.isSuccess(), 'Save should have been blocked');
        return result.getErrors()[0].getMessage();
    }

    // ------------------------------------------------------------ InventoryTrigger

    @IsTest
    static void testInventoryDefaultsBlankStockFieldsAndStampsStockCheck() {
        Inventory__c inv = new Inventory__c(Product__c = products()[0].Id, Warehouse__c = warehouse().Id);
        insert inv;
        Inventory__c saved = [SELECT On_Hand__c, Reserved__c, On_Order__c, Last_Stock_Check__c FROM Inventory__c WHERE Id = :inv.Id];
        System.assertEquals(0, saved.On_Hand__c);
        System.assertEquals(0, saved.Reserved__c);
        System.assertEquals(0, saved.On_Order__c);
        System.assertEquals(Date.today(), saved.Last_Stock_Check__c);
    }

    @IsTest
    static void testInventoryRejectsNegativeStock() {
        Inventory__c inv = new Inventory__c(Product__c = products()[0].Id, Warehouse__c = warehouse().Id, On_Hand__c = -5);
        Database.SaveResult result = Database.insert(inv, false);
        System.assertEquals(false, result.isSuccess());
        System.assertEquals(0, [SELECT COUNT() FROM Inventory__c]);
    }

    @IsTest
    static void testInventoryRejectsDuplicateProductWarehouse() {
        Id productId = products()[0].Id;
        insert new Inventory__c(Product__c = productId, Warehouse__c = warehouse().Id, On_Hand__c = 5);
        String error = firstError(Database.insert(new Inventory__c(Product__c = productId, Warehouse__c = warehouse().Id, On_Hand__c = 1), false));
        System.assert(error.contains('already exists'), error);

        List<Inventory__c> sameBatch = new List<Inventory__c>{
            new Inventory__c(Product__c = products()[1].Id, Warehouse__c = warehouse().Id),
            new Inventory__c(Product__c = products()[1].Id, Warehouse__c = warehouse().Id)
        };
        List<Database.SaveResult> results = Database.insert(sameBatch, false);
        System.assertEquals(true, results[0].isSuccess());
        System.assert(firstError(results[1]).contains('this request'), 'Second record in the batch is the duplicate');
    }

    @IsTest
    static void testInventoryBulkInsertAndStockCheckUpdate() {
        List<Inventory__c> records = new List<Inventory__c>();
        for (Product2 p : products()) records.add(new Inventory__c(Product__c = p.Id, Warehouse__c = warehouse().Id, On_Hand__c = 10));
        insert records;
        System.assertEquals(20, [SELECT COUNT() FROM Inventory__c WHERE Last_Stock_Check__c = :Date.today()]);

        for (Inventory__c inv : records) {
            inv.Last_Stock_Check__c = Date.today().addDays(-30);
        }
        update records;
        for (Inventory__c inv : records) inv.On_Hand__c = 25;
        update records;
        // A stock change without a manual date change refreshes the stock check date; the manual date was kept stable first.
        System.assertEquals(20, [SELECT COUNT() FROM Inventory__c WHERE On_Hand__c = 25 AND Last_Stock_Check__c = :Date.today()]);
    }

    @IsTest
    static void testInventoryRejectsMovingToOccupiedLocation() {
        Id warehouseId = warehouse().Id;
        insert new Inventory__c(Product__c = products()[0].Id, Warehouse__c = warehouseId);
        Inventory__c other = new Inventory__c(Product__c = products()[1].Id, Warehouse__c = warehouseId);
        insert other;
        other.Product__c = products()[0].Id;
        System.assert(firstError(Database.update(other, false)).contains('already exists'));
    }

    // ------------------------------------------------------------ RequisitionTrigger

    private static Purchase_Requisition__c createRequisition(Boolean withLine) {
        Purchase_Requisition__c req = new Purchase_Requisition__c(
            Destination_Warehouse__c = warehouse().Id, Request_Date__c = Date.today(),
            Status__c = 'Draft', Source__c = 'Manual', Requester__c = UserInfo.getUserId()
        );
        insert req;
        if (withLine) {
            insert new Requisition_Line__c(
                Requisition__c = req.Id, Product__c = products()[0].Id, Requested_Qty__c = 5, Estimated_Unit_Price__c = 20
            );
        }
        return req;
    }

    @IsTest
    static void testRequisitionRejectsInvalidTransitions() {
        Purchase_Requisition__c req = createRequisition(true);
        req.Status__c = 'Approved';
        String error = firstError(Database.update(req, false));
        System.assert(error.contains('cannot move from Draft to Approved'), error);
        System.assertEquals('Draft', [SELECT Status__c FROM Purchase_Requisition__c WHERE Id = :req.Id].Status__c);
    }

    @IsTest
    static void testRequisitionSubmissionRequiresLines() {
        Purchase_Requisition__c req = createRequisition(false);
        req.Status__c = 'Submitted';
        String error = firstError(Database.update(req, false));
        System.assert(error.contains('at least one requisition line'), error);
    }

    @IsTest
    static void testRequisitionSubmissionRejectsInvalidLine() {
        Purchase_Requisition__c req = createRequisition(true);
        req.Status__c = 'Submitted';
        req.Required_By__c = Date.today().addDays(-1);
        String error = firstError(Database.update(req, false));
        System.assert(error.contains('Required By date'), error);
    }

    @IsTest
    static void testRequisitionValidSubmissionAndCancellation() {
        ProcurementTestUtil.addCurrentUserToQueues(new List<String>{ 'Procurement_Approvers' });
        Purchase_Requisition__c req = createRequisition(true);
        Test.startTest();
        req.Status__c = 'Submitted';
        update req;
        Test.stopTest();
        System.assertNotEquals('Draft', [SELECT Status__c FROM Purchase_Requisition__c WHERE Id = :req.Id].Status__c);

        Purchase_Requisition__c cancelled = createRequisition(false);
        cancelled.Status__c = 'Cancelled';
        update cancelled;
        cancelled.Status__c = 'Draft';
        System.assert(firstError(Database.update(cancelled, false)).contains('cannot move from Cancelled'));
    }

    @IsTest
    static void testRequisitionBulkUpdateReportsEachRecord() {
        List<Purchase_Requisition__c> reqs = new List<Purchase_Requisition__c>();
        for (Integer i = 0; i < 10; i++) reqs.add(createRequisition(i < 5));
        for (Purchase_Requisition__c req : reqs) req.Status__c = 'Ordered';
        List<Database.SaveResult> results = Database.update(reqs, false);
        for (Database.SaveResult result : results) {
            System.assertEquals(false, result.isSuccess());
        }
    }

    // ------------------------------------------------------------ PurchaseOrderTrigger

    @IsTest
    static void testPurchaseOrderRejectsInvalidTransitionAndPrematureSent() {
        Purchase_Order__c draft = createOrder('Draft');
        draft.Status__c = 'Received';
        System.assert(firstError(Database.update(draft, false)).contains('cannot move from Draft to Received'));

        Purchase_Order__c approved = createOrder('Approved');
        approved.Status__c = 'Sent';
        System.assert(firstError(Database.update(approved, false)).contains('supplier confirms'));
        System.assertEquals('Approved', [SELECT Status__c FROM Purchase_Order__c WHERE Id = :approved.Id].Status__c);
    }

    @IsTest
    static void testPurchaseOrderDispatchRequestRequiresApproval() {
        Purchase_Order__c draft = createOrder('Draft');
        draft.Last_Sync_Status__c = 'Pending';
        System.assert(firstError(Database.update(draft, false)).contains('approved purchase order'));
    }

    @IsTest
    static void testPurchaseOrderCancellationRules() {
        Purchase_Order__c received = createOrder('Approved');
        Purchase_Order_Line__c line = [SELECT Id FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :received.Id];
        update new Purchase_Order_Line__c(Id = line.Id, Quantity_Received__c = 5);
        received.Status__c = 'Cancelled';
        System.assert(firstError(Database.update(received, false)).contains('received goods'));

        Purchase_Order__c inFlight = createOrder('Approved');
        inFlight.Status__c = 'Cancelled';
        inFlight.Last_Sync_Status__c = 'Pending';
        System.assertEquals(false, Database.update(inFlight, false).isSuccess(), 'Cancelling while requesting dispatch is blocked');

        Purchase_Order__c cancellable = createOrder('Draft');
        cancellable.Status__c = 'Cancelled';
        update cancellable;
        System.assertEquals('Cancelled', [SELECT Status__c FROM Purchase_Order__c WHERE Id = :cancellable.Id].Status__c);
        cancellable.Status__c = 'Draft';
        System.assertEquals(false, Database.update(cancellable, false).isSuccess());
    }

    @IsTest
    static void testPurchaseOrderLockedAfterDispatch() {
        Purchase_Order__c po = createOrder('Approved');
        update new Purchase_Order__c(Id = po.Id, External_Order_Id__c = 'EXT-1');

        Purchase_Order__c changeTax = new Purchase_Order__c(Id = po.Id, Tax_Amount__c = 99);
        System.assert(firstError(Database.update(changeTax, false)).contains('after the purchase order has been dispatched'));
        Purchase_Order__c changeId = new Purchase_Order__c(Id = po.Id, External_Order_Id__c = 'EXT-2');
        System.assert(firstError(Database.update(changeId, false)).contains('external order ID'));

        Database.SaveResult statusChange = Database.update(new Purchase_Order__c(Id = po.Id, Status__c = 'Partially Received'), false);
        System.assertEquals(true, statusChange.isSuccess(), 'Receiving goods remains possible after dispatch');
    }

    @IsTest
    static void testPurchaseOrderBulkUpdate() {
        List<Purchase_Order__c> orders = new List<Purchase_Order__c>();
        for (Integer i = 0; i < 10; i++) orders.add(createOrder(Math.mod(i, 2) == 0 ? 'Draft' : 'Approved'));
        for (Purchase_Order__c po : orders) po.Status__c = 'Received';
        List<Database.SaveResult> results = Database.update(orders, false);
        Integer failures = 0;
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) failures++;
        }
        System.assertEquals(5, failures, 'Draft orders cannot be received; approved orders can');
    }

    // ------------------------------------------------------------ GoodsReceiptTrigger

    @IsTest
    static void testGoodsReceiptCannotBePostedManually() {
        Goods_Receipt__c gr = createReceipt(createOrder('Sent'), 'Inspecting');
        gr.Status__c = 'Posted';
        System.assert(firstError(Database.update(gr, false)).contains('posting process'));
        gr.Status__c = 'Inspecting';
        gr.Posted_At__c = Datetime.now();
        System.assert(firstError(Database.update(gr, false)).contains('Posted At'));
        System.assertEquals('Inspecting', [SELECT Status__c FROM Goods_Receipt__c WHERE Id = :gr.Id].Status__c);
    }

    @IsTest
    static void testGoodsReceiptPostedAndRejectedAreFinal() {
        Purchase_Order__c po = createOrder('Sent');
        Purchase_Order_Line__c pol = [SELECT Id FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :po.Id];
        insert new Inventory__c(Product__c = products()[0].Id, Warehouse__c = warehouse().Id, On_Order__c = 50);
        Goods_Receipt__c gr = createReceipt(po, 'Inspecting');
        insert receiptLine(gr.Id, pol.Id, 10, 10, 0, null);

        GoodsReceiptService.postGoodsReceipt(gr.Id);
        System.assertEquals('Posted', [SELECT Status__c FROM Goods_Receipt__c WHERE Id = :gr.Id].Status__c);

        gr.Status__c = 'Draft';
        System.assertEquals(false, Database.update(gr, false).isSuccess(), 'Posted receipts cannot go back');
        try {
            GoodsReceiptService.postGoodsReceipt(gr.Id);
            System.assert(false, 'Duplicate posting must be blocked');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('already been posted'), e.getMessage());
        }
        System.assertEquals(10, [SELECT On_Hand__c FROM Inventory__c LIMIT 1].On_Hand__c, 'Stock is not posted twice');

        Goods_Receipt__c rejected = createReceipt(po, 'Inspecting');
        rejected.Status__c = 'Rejected';
        update rejected;
        rejected.Status__c = 'Inspecting';
        System.assertEquals(false, Database.update(rejected, false).isSuccess());
    }

    @IsTest
    static void testGoodsReceiptAllowsDraftToInspecting() {
        Goods_Receipt__c gr = createReceipt(createOrder('Sent'), 'Draft');
        gr.Status__c = 'Inspecting';
        update gr;
        System.assertEquals('Inspecting', [SELECT Status__c FROM Goods_Receipt__c WHERE Id = :gr.Id].Status__c);
    }

    // ------------------------------------------------------------ GoodsReceiptLineTrigger

    @IsTest
    static void testReceiptLineQuantityValidation() {
        Purchase_Order__c po = createOrder('Sent');
        Purchase_Order_Line__c pol = [SELECT Id FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :po.Id];
        Goods_Receipt__c gr = createReceipt(po, 'Inspecting');

        System.assertEquals(false, Database.insert(receiptLine(gr.Id, pol.Id, 10, 9, 5, 'Damage'), false).isSuccess(), 'Accepted + rejected above delivered');
        System.assert(firstError(Database.insert(receiptLine(gr.Id, pol.Id, 10, 8, 2, null), false)).contains('rejection reason'));
        System.assert(firstError(Database.insert(receiptLine(gr.Id, pol.Id, 60, 60, 0, null), false)).contains('exceeds the outstanding'));
        System.assertEquals(true, Database.insert(receiptLine(gr.Id, pol.Id, 10, 8, 2, 'Damage'), false).isSuccess());
    }

    @IsTest
    static void testReceiptLineBulkInsertAndUpdate() {
        Purchase_Order__c po = createOrder('Sent');
        Purchase_Order_Line__c pol = [SELECT Id FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :po.Id];
        Goods_Receipt__c gr = createReceipt(po, 'Inspecting');

        List<Goods_Receipt_Line__c> lines = new List<Goods_Receipt_Line__c>();
        for (Integer i = 0; i < 6; i++) lines.add(receiptLine(gr.Id, pol.Id, 10, 10, 0, null));
        List<Database.SaveResult> results = Database.insert(lines, false);
        Integer saved = 0;
        for (Database.SaveResult result : results) {
            if (result.isSuccess()) saved++;
        }
        System.assertEquals(5, saved, 'Only 50 units are outstanding, so the sixth 10-unit line is rejected');
        System.assertEquals(false, results[5].isSuccess());

        Goods_Receipt_Line__c first = lines[0];
        first.Quantity_Accepted__c = 70;
        first.Quantity_Delivered__c = 70;
        System.assertEquals(false, Database.update(first, false).isSuccess(), 'Update above outstanding is blocked');
    }

    @IsTest
    static void testReceiptLineRejectedForWrongOrderPostedReceiptAndCancelledLine() {
        Purchase_Order__c po = createOrder('Sent');
        Purchase_Order__c otherPo = createOrder('Sent');
        Purchase_Order_Line__c otherLine = [SELECT Id FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :otherPo.Id];
        Purchase_Order_Line__c pol = [SELECT Id FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :po.Id];
        Goods_Receipt__c gr = createReceipt(po, 'Inspecting');

        System.assert(firstError(Database.insert(receiptLine(gr.Id, otherLine.Id, 5, 5, 0, null), false)).contains('does not belong'));

        Goods_Receipt_Line__c existing = receiptLine(gr.Id, pol.Id, 5, 5, 0, null);
        insert existing;
        Goods_Receipt__c rejectedReceipt = createReceipt(po, 'Rejected');
        System.assert(firstError(Database.insert(receiptLine(rejectedReceipt.Id, pol.Id, 1, 1, 0, null), false)).contains('cannot be changed'));

        update new Purchase_Order_Line__c(Id = pol.Id, Line_Status__c = 'Cancelled');
        System.assert(firstError(Database.insert(receiptLine(gr.Id, pol.Id, 1, 1, 0, null), false)).contains('cancelled'));
    }
}
