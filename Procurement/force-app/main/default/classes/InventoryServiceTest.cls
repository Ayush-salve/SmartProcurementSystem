@IsTest
private class InventoryServiceTest {

    @TestSetup
    static void setupData() {
        Warehouse__c wh = new Warehouse__c(Name = 'Test WH', Warehouse_Code__c = 'TWH', Active__c = true);
        insert wh;
        Product2 prod = new Product2(Name = 'Test Product', IsActive = true);
        insert prod;
        Inventory__c inv = new Inventory__c(
            Product__c = prod.Id, Warehouse__c = wh.Id,
            On_Hand__c = 100, Reserved__c = 20, On_Order__c = 50,
            Safety_Stock__c = 10, Reorder_Point__c = 30,
            Average_Daily_Demand__c = 5, Lead_Time_Days__c = 7,
            Reorder_Status__c = 'Healthy'
        );
        insert inv;
    }

    @IsTest
    static void testGetInventoryRecords() {
        Test.startTest();
        List<InventoryService.InventoryWrapper> results = InventoryService.getInventoryRecords(null, null);
        Test.stopTest();
        System.assert(results.size() > 0, 'Should return inventory records');
        System.assertEquals('Test Product', results[0].productName);
    }

    @IsTest
    static void testGetInventoryRecordsWithSearch() {
        Test.startTest();
        List<InventoryService.InventoryWrapper> results = InventoryService.getInventoryRecords('Test', null);
        List<InventoryService.InventoryWrapper> empty = InventoryService.getInventoryRecords('ZZZ_NoMatch', null);
        Test.stopTest();
        System.assert(results.size() > 0);
        System.assertEquals(0, empty.size());
    }

    @IsTest
    static void testEvaluateReorderStatuses() {
        Test.startTest();
        Integer updated = InventoryService.evaluateAndUpdateReorderStatuses();
        Test.stopTest();
        System.assert(updated >= 0);
    }

    @IsTest
    static void testUpdateReorderStatus() {
        Inventory__c inv = [SELECT Id FROM Inventory__c LIMIT 1];
        Test.startTest();
        Boolean result = InventoryService.updateReorderStatus(inv.Id, 'Reorder Needed');
        Test.stopTest();
        System.assert(result);
        Inventory__c updated = [SELECT Reorder_Status__c FROM Inventory__c WHERE Id = :inv.Id];
        System.assertEquals('Reorder Needed', updated.Reorder_Status__c);
    }

    @IsTest
    static void testGetActiveWarehouses() {
        Test.startTest();
        List<Warehouse__c> whs = InventoryService.getActiveWarehouses();
        Test.stopTest();
        System.assert(whs.size() > 0);
    }
}
