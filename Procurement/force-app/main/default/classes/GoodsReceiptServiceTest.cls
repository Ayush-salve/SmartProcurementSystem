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

    @IsTest
    static void testSaveGoodsReceipt() {
        Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c LIMIT 1];
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Goods_Receipt__c gr = new Goods_Receipt__c(
            Purchase_Order__c = po.Id, Warehouse__c = wh.Id,
            Receipt_Date__c = Date.today()
        );
        Test.startTest();
        Id grId = GoodsReceiptService.saveGoodsReceipt(JSON.serialize(gr), JSON.serialize(new List<Goods_Receipt_Line__c>()));
        Test.stopTest();
        System.assertNotEquals(null, grId);
        Goods_Receipt__c saved = [SELECT Status__c FROM Goods_Receipt__c WHERE Id = :grId];
        System.assertEquals('Draft', saved.Status__c);
    }

    @IsTest
    static void testPostGoodsReceipt() {
        Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c LIMIT 1];
        Purchase_Order_Line__c pol = [SELECT Id FROM Purchase_Order_Line__c LIMIT 1];
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Goods_Receipt__c gr = new Goods_Receipt__c(
            Purchase_Order__c = po.Id, Warehouse__c = wh.Id,
            Receipt_Date__c = Date.today(), Status__c = 'Inspecting',
            Received_By__c = UserInfo.getUserId()
        );
        insert gr;
        Goods_Receipt_Line__c grl = new Goods_Receipt_Line__c(
            Goods_Receipt__c = gr.Id,
            Purchase_Order_Line__c = pol.Id,
            Quantity_Delivered__c = 30,
            Quantity_Accepted__c = 30,
            Quantity_Rejected__c = 0
        );
        insert grl;
        Test.startTest();
        GoodsReceiptService.postGoodsReceipt(gr.Id);
        Test.stopTest();
        Goods_Receipt__c posted = [SELECT Status__c, Posted_At__c FROM Goods_Receipt__c WHERE Id = :gr.Id];
        System.assertEquals('Posted', posted.Status__c);
        System.assertNotEquals(null, posted.Posted_At__c);
        Inventory__c inv = [SELECT On_Hand__c FROM Inventory__c LIMIT 1];
        System.assertEquals(30, inv.On_Hand__c);
        List<Inventory_Transaction__c> txs = [SELECT Id FROM Inventory_Transaction__c];
        System.assertEquals(1, txs.size(), 'Should have 1 inventory transaction');
    }

    @IsTest
    static void testDuplicatePostPrevented() {
        Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c LIMIT 1];
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Goods_Receipt__c gr = new Goods_Receipt__c(
            Purchase_Order__c = po.Id, Warehouse__c = wh.Id,
            Receipt_Date__c = Date.today(), Status__c = 'Posted', Posted_At__c = Datetime.now(),
            Received_By__c = UserInfo.getUserId()
        );
        insert gr;
        Test.startTest();
        try {
            GoodsReceiptService.postGoodsReceipt(gr.Id);
            System.assert(false, 'Should throw for already posted');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('already been posted'));
        }
        Test.stopTest();
    }
}
