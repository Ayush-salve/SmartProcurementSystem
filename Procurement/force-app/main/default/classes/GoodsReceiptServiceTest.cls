@IsTest
private class GoodsReceiptServiceTest {

    @TestSetup
    static void setupData() {
        Warehouse__c wh = new Warehouse__c(Name = 'GR Test WH', Warehouse_Code__c = 'GRWH', Active__c = true);
        insert wh;
        Product2 prod = new Product2(Name = 'GR Test Product', IsActive = true);
        insert prod;
        Account supplier = new Account(Name = 'GR Test Supplier');
        insert supplier;
        Inventory__c inv = new Inventory__c(
            Product__c = prod.Id, Warehouse__c = wh.Id,
            On_Hand__c = 0, Reserved__c = 0, On_Order__c = 100,
            Reorder_Status__c = 'Reorder Needed'
        );
        insert inv;
        Purchase_Order__c po = new Purchase_Order__c(
            Supplier__c = supplier.Id, Warehouse__c = wh.Id,
            Order_Date__c = Date.today(), Status__c = 'Sent'
        );
        insert po;
        Purchase_Order_Line__c pol = new Purchase_Order_Line__c(
            Purchase_Order__c = po.Id, Product__c = prod.Id,
            Quantity_Ordered__c = 50, Quantity_Received__c = 0,
            Unit_Price__c = 10, Line_Status__c = 'Open'
        );
        insert pol;
    }

    private static Goods_Receipt__c createReceipt(Decimal delivered, Decimal accepted, Decimal rejected, String reason) {
        Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c LIMIT 1];
        Purchase_Order_Line__c pol = [SELECT Id FROM Purchase_Order_Line__c LIMIT 1];
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Goods_Receipt__c gr = new Goods_Receipt__c(
            Purchase_Order__c = po.Id, Warehouse__c = wh.Id,
            Receipt_Date__c = Date.today(), Status__c = 'Inspecting',
            Received_By__c = UserInfo.getUserId()
        );
        insert gr;
        insert new Goods_Receipt_Line__c(
            Goods_Receipt__c = gr.Id, Purchase_Order_Line__c = pol.Id,
            Quantity_Delivered__c = delivered, Quantity_Accepted__c = accepted,
            Quantity_Rejected__c = rejected, Rejection_Reason__c = reason
        );
        return gr;
    }

    private static GoodsReceiptService.PostReceiptResult callInvocable(Id receiptId) {
        GoodsReceiptService.PostReceiptInput input = new GoodsReceiptService.PostReceiptInput();
        input.receiptId = String.valueOf(receiptId);
        return GoodsReceiptService.postGoodsReceiptFromFlow(new List<GoodsReceiptService.PostReceiptInput>{ input })[0];
    }

    @IsTest
    static void testSaveGoodsReceiptDefaultsWarehouseFromPurchaseOrder() {
        Purchase_Order__c po = [SELECT Id, Warehouse__c FROM Purchase_Order__c LIMIT 1];
        Goods_Receipt__c gr = new Goods_Receipt__c(Purchase_Order__c = po.Id, Receipt_Date__c = Date.today());
        Test.startTest();
        Id grId = GoodsReceiptService.saveGoodsReceipt(JSON.serialize(gr), JSON.serialize(new List<Goods_Receipt_Line__c>()));
        Test.stopTest();
        Goods_Receipt__c saved = [SELECT Status__c, Warehouse__c FROM Goods_Receipt__c WHERE Id = :grId];
        System.assertEquals('Draft', saved.Status__c);
        System.assertEquals(po.Warehouse__c, saved.Warehouse__c, 'Warehouse should default from the purchase order');
    }

    @IsTest
    static void testSaveRejectsRejectedQuantityWithoutReason() {
        Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c LIMIT 1];
        Purchase_Order_Line__c pol = [SELECT Id FROM Purchase_Order_Line__c LIMIT 1];
        Goods_Receipt__c gr = new Goods_Receipt__c(Purchase_Order__c = po.Id);
        Goods_Receipt_Line__c line = new Goods_Receipt_Line__c(
            Purchase_Order_Line__c = pol.Id, Quantity_Delivered__c = 10, Quantity_Accepted__c = 8, Quantity_Rejected__c = 2
        );
        try {
            GoodsReceiptService.saveGoodsReceipt(JSON.serialize(gr), JSON.serialize(new List<Goods_Receipt_Line__c>{ line }));
            System.assert(false, 'Should require a rejection reason');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('rejection reason'), e.getMessage());
        }
        System.assertEquals(0, [SELECT COUNT() FROM Goods_Receipt__c], 'Nothing should be saved');
    }

    @IsTest
    static void testSaveRejectsAcceptedPlusRejectedAboveDelivered() {
        Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c LIMIT 1];
        Purchase_Order_Line__c pol = [SELECT Id FROM Purchase_Order_Line__c LIMIT 1];
        Goods_Receipt__c gr = new Goods_Receipt__c(Purchase_Order__c = po.Id);
        Goods_Receipt_Line__c line = new Goods_Receipt_Line__c(
            Purchase_Order_Line__c = pol.Id, Quantity_Delivered__c = 10, Quantity_Accepted__c = 9, Quantity_Rejected__c = 5,
            Rejection_Reason__c = 'Damage'
        );
        try {
            GoodsReceiptService.saveGoodsReceipt(JSON.serialize(gr), JSON.serialize(new List<Goods_Receipt_Line__c>{ line }));
            System.assert(false, 'Should reject invalid quantities');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('cannot exceed the delivered'), e.getMessage());
        }
    }

    @IsTest
    static void testPostGoodsReceiptUpdatesEverythingAtomically() {
        Goods_Receipt__c gr = createReceipt(30, 30, 0, null);
        Test.startTest();
        GoodsReceiptService.postGoodsReceipt(gr.Id);
        Test.stopTest();

        Goods_Receipt__c posted = [SELECT Status__c, Posted_At__c FROM Goods_Receipt__c WHERE Id = :gr.Id];
        System.assertEquals('Posted', posted.Status__c);
        System.assertNotEquals(null, posted.Posted_At__c);
        Inventory__c inv = [SELECT On_Hand__c, On_Order__c FROM Inventory__c LIMIT 1];
        System.assertEquals(30, inv.On_Hand__c);
        System.assertEquals(70, inv.On_Order__c);
        List<Inventory_Transaction__c> txs = [
            SELECT Quantity_Before__c, Quantity_After__c, Quantity_Change__c, Transaction_Type__c
            FROM Inventory_Transaction__c
        ];
        System.assertEquals(1, txs.size(), 'Should have 1 inventory transaction');
        System.assertEquals('Receipt', txs[0].Transaction_Type__c);
        System.assertEquals(0, txs[0].Quantity_Before__c);
        System.assertEquals(30, txs[0].Quantity_After__c);
        Purchase_Order_Line__c pol = [SELECT Quantity_Received__c, Line_Status__c FROM Purchase_Order_Line__c LIMIT 1];
        System.assertEquals(30, pol.Quantity_Received__c);
        System.assertEquals('Partially Received', pol.Line_Status__c);
        System.assertEquals('Partially Received', [SELECT Status__c FROM Purchase_Order__c LIMIT 1].Status__c);
    }

    @IsTest
    static void testPartialDeliveriesThenCompletion() {
        Goods_Receipt__c first = createReceipt(30, 30, 0, null);
        GoodsReceiptService.postGoodsReceipt(first.Id);

        Goods_Receipt__c second = createReceipt(25, 20, 5, 'Damage');
        GoodsReceiptService.postGoodsReceipt(second.Id);

        Purchase_Order_Line__c pol = [SELECT Quantity_Received__c, Quantity_Rejected__c, Line_Status__c FROM Purchase_Order_Line__c LIMIT 1];
        System.assertEquals(50, pol.Quantity_Received__c);
        System.assertEquals(5, pol.Quantity_Rejected__c);
        System.assertEquals('Complete', pol.Line_Status__c);
        System.assertEquals('Received', [SELECT Status__c FROM Purchase_Order__c LIMIT 1].Status__c);
        System.assertEquals(50, [SELECT On_Hand__c FROM Inventory__c LIMIT 1].On_Hand__c);
        System.assertEquals(2, [SELECT COUNT() FROM Inventory_Transaction__c]);
    }

    @IsTest
    static void testDuplicatePostPrevented() {
        Goods_Receipt__c gr = createReceipt(10, 10, 0, null);
        GoodsReceiptService.postGoodsReceipt(gr.Id);
        try {
            GoodsReceiptService.postGoodsReceipt(gr.Id);
            System.assert(false, 'Should throw for already posted');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('already been posted'), e.getMessage());
        }
        System.assertEquals(10, [SELECT On_Hand__c FROM Inventory__c LIMIT 1].On_Hand__c, 'Stock must not be doubled');
        System.assertEquals(1, [SELECT COUNT() FROM Inventory_Transaction__c]);
    }

    @IsTest
    static void testDuplicateTransactionKeyBlocksRepost() {
        Goods_Receipt__c gr = createReceipt(10, 10, 0, null);
        Goods_Receipt_Line__c line = [SELECT Id FROM Goods_Receipt_Line__c WHERE Goods_Receipt__c = :gr.Id];
        Inventory__c inv = [SELECT Id, Product__c, Warehouse__c FROM Inventory__c LIMIT 1];
        insert new Inventory_Transaction__c(
            Inventory__c = inv.Id, Product__c = inv.Product__c, Warehouse__c = inv.Warehouse__c,
            Transaction_Type__c = 'Receipt', Quantity_Change__c = 10, Quantity_Before__c = 0, Quantity_After__c = 10,
            Transaction_Key__c = gr.Id + '-' + line.Id
        );
        GoodsReceiptService.PostReceiptResult result = callInvocable(gr.Id);
        System.assertEquals(false, result.isSuccess);
        System.assert(result.message.contains('already been posted'), result.message);
        System.assertEquals('Inspecting', [SELECT Status__c FROM Goods_Receipt__c WHERE Id = :gr.Id].Status__c);
    }

    @IsTest
    static void testInvalidQuantitiesAreRejectedWithoutChanges() {
        try {
            createReceipt(10, 8, 2, null);
            System.assert(false, 'GoodsReceiptLineTrigger must reject a rejected quantity without a reason');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('rejection reason'), e.getMessage());
        }
        System.assertEquals(0, [SELECT On_Hand__c FROM Inventory__c LIMIT 1].On_Hand__c);
        System.assertEquals(0, [SELECT COUNT() FROM Inventory_Transaction__c]);
    }

    @IsTest
    static void testAcceptedAboveOutstandingIsRejected() {
        try {
            createReceipt(60, 60, 0, null);
            System.assert(false, 'GoodsReceiptLineTrigger must reject quantities above the outstanding order quantity');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('exceeds the outstanding quantity'), e.getMessage());
        }
        System.assertEquals(0, [SELECT COUNT() FROM Inventory_Transaction__c]);
    }

    @IsTest
    static void testFailureAfterStockUpdateRollsBackEverything() {
        Goods_Receipt__c gr = createReceipt(30, 30, 0, null);
        GoodsReceiptService.simulateFailureAfterStockUpdate = true;
        Test.startTest();
        GoodsReceiptService.PostReceiptResult result = callInvocable(gr.Id);
        Test.stopTest();

        System.assertEquals(false, result.isSuccess);
        System.assert(result.message.contains('Simulated failure'), result.message);
        System.assertEquals(0, [SELECT On_Hand__c FROM Inventory__c LIMIT 1].On_Hand__c, 'Stock update must be rolled back');
        System.assertEquals(0, [SELECT COUNT() FROM Inventory_Transaction__c], 'Transactions must be rolled back');
        Purchase_Order_Line__c pol = [SELECT Quantity_Received__c, Line_Status__c FROM Purchase_Order_Line__c LIMIT 1];
        System.assertEquals(0, pol.Quantity_Received__c, 'PO line must be rolled back');
        System.assertEquals('Open', pol.Line_Status__c);
        System.assertEquals('Sent', [SELECT Status__c FROM Purchase_Order__c LIMIT 1].Status__c);
        System.assertEquals('Inspecting', [SELECT Status__c FROM Goods_Receipt__c WHERE Id = :gr.Id].Status__c);
    }

    @IsTest
    static void testCancelledPurchaseOrderCannotBeReceived() {
        Goods_Receipt__c gr = createReceipt(10, 10, 0, null);
        update new Purchase_Order__c(Id = [SELECT Id FROM Purchase_Order__c LIMIT 1].Id, Status__c = 'Cancelled');
        // The No_Receipt_Against_Cancelled_PO validation rule locks the receipt, so assert on the service guard via the PO status.
        GoodsReceiptService.PostReceiptResult result = callInvocable(gr.Id);
        System.assertEquals(false, result.isSuccess);
        System.assertEquals(0, [SELECT COUNT() FROM Inventory_Transaction__c]);
    }

    @IsTest
    static void testMissingInventoryRecordRollsBack() {
        Goods_Receipt__c gr = createReceipt(10, 10, 0, null);
        delete [SELECT Id FROM Inventory__c];
        GoodsReceiptService.PostReceiptResult result = callInvocable(gr.Id);
        System.assertEquals(false, result.isSuccess);
        System.assert(result.message.contains('No inventory record'), result.message);
        System.assertEquals('Inspecting', [SELECT Status__c FROM Goods_Receipt__c WHERE Id = :gr.Id].Status__c);
    }

    @IsTest
    static void testPostingFlowPostsThenBlocksDuplicate() {
        Goods_Receipt__c gr = createReceipt(20, 20, 0, null);
        Test.startTest();
        Flow.Interview flow1 = Flow.Interview.createInterview('Goods_Receipt_Posting', new Map<String, Object>{ 'receiptId' => String.valueOf(gr.Id) });
        flow1.start();
        Boolean firstOk = (Boolean) flow1.getVariableValue('isSuccess');
        Flow.Interview flow2 = Flow.Interview.createInterview('Goods_Receipt_Posting', new Map<String, Object>{ 'receiptId' => String.valueOf(gr.Id) });
        flow2.start();
        Test.stopTest();
        System.assertEquals(true, firstOk, String.valueOf(flow1.getVariableValue('resultMessage')));
        System.assertEquals(false, (Boolean) flow2.getVariableValue('isSuccess'));
        System.assert(String.valueOf(flow2.getVariableValue('resultMessage')).contains('already been posted'));
        System.assertEquals('Partially Received', String.valueOf(flow1.getVariableValue('purchaseOrderStatus')));
        System.assertEquals(20, [SELECT On_Hand__c FROM Inventory__c LIMIT 1].On_Hand__c);
        System.assertEquals(1, [SELECT COUNT() FROM Inventory_Transaction__c]);
    }

    @IsTest
    static void testPostingFlowRejectsReceiptWithoutLines() {
        Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c LIMIT 1];
        Goods_Receipt__c gr = new Goods_Receipt__c(Purchase_Order__c = po.Id, Status__c = 'Inspecting', Receipt_Date__c = Date.today());
        insert gr;
        Flow.Interview flow = Flow.Interview.createInterview('Goods_Receipt_Posting', new Map<String, Object>{ 'receiptId' => String.valueOf(gr.Id) });
        flow.start();
        System.assertEquals(false, (Boolean) flow.getVariableValue('isSuccess'));
        System.assert(String.valueOf(flow.getVariableValue('resultMessage')).contains('no lines'));
    }

    @IsTest
    static void testGetPurchaseOrderForReceiptAndRecentReceipts() {
        Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c LIMIT 1];
        createReceipt(5, 5, 0, null);
        GoodsReceiptService.PoForReceipt data = GoodsReceiptService.getPurchaseOrderForReceipt(po.Id);
        System.assertEquals(1, data.lines.size());
        System.assertEquals(50, data.lines[0].remaining);
        System.assertEquals(1, GoodsReceiptService.getRecentReceipts(10).size());
    }
}
