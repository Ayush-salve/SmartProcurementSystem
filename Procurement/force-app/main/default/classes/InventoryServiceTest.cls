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

    @IsTest
    static void testClassifyReorderStatus() {
        System.assertEquals('Reorder Needed', InventoryService.classifyReorderStatus(10, 0, 10));
        System.assertEquals('Reorder Needed', InventoryService.classifyReorderStatus(5, 10, 10));
        System.assertEquals('At Risk', InventoryService.classifyReorderStatus(11, 0, 10));
        System.assertEquals('Healthy', InventoryService.classifyReorderStatus(13, 0, 10));
        System.assertEquals('Healthy', InventoryService.classifyReorderStatus(1, 0, null));
    }

    @IsTest
    static void testInvocableUpdatesOnlyWhenStatusChanges() {
        Inventory__c inv = [SELECT Id FROM Inventory__c LIMIT 1];
        InventoryService.ReorderEvaluationRequest req = new InventoryService.ReorderEvaluationRequest();
        req.inventoryId = inv.Id;

        InventoryService.ReorderEvaluationResult unchanged =
            InventoryService.evaluateReorderFromFlow(new List<InventoryService.ReorderEvaluationRequest>{ req })[0];
        System.assertEquals('Healthy', unchanged.reorderStatus);
        System.assertEquals(false, unchanged.statusChanged);

        update new Inventory__c(Id = inv.Id, On_Hand__c = 40);
        Inventory__c refreshed = [SELECT Reorder_Status__c, Last_Reorder_Run__c FROM Inventory__c WHERE Id = :inv.Id];
        System.assertEquals('Reorder Needed', refreshed.Reorder_Status__c, 'The flow should have reclassified the stock change');
        System.assertNotEquals(null, refreshed.Last_Reorder_Run__c);
    }

    @IsTest
    static void testInvocableReportsMissingInventory() {
        InventoryService.ReorderEvaluationRequest req = new InventoryService.ReorderEvaluationRequest();
        req.inventoryId = Id.valueOf('a00000000000000AAA');
        InventoryService.ReorderEvaluationResult res =
            InventoryService.evaluateReorderFromFlow(new List<InventoryService.ReorderEvaluationRequest>{ req })[0];
        System.assertEquals(false, res.statusChanged);
        System.assert(res.message.contains('not found'));
    }

    @IsTest
    static void testFlowSetsStatusOnInsertAndAlertsWarehouseManagerOnce() {
        Warehouse__c wh = new Warehouse__c(Name = 'Managed WH', Warehouse_Code__c = 'MWH', Active__c = true, Manager__c = UserInfo.getUserId());
        insert wh;
        Product2 prod = new Product2(Name = 'Low Stock Product', IsActive = true);
        insert prod;
        Test.startTest();
        Inventory__c inv = new Inventory__c(
            Product__c = prod.Id, Warehouse__c = wh.Id, On_Hand__c = 5, Reserved__c = 0, Reorder_Point__c = 20
        );
        insert inv;
        Test.stopTest();

        System.assertEquals('Reorder Needed', [SELECT Reorder_Status__c FROM Inventory__c WHERE Id = :inv.Id].Reorder_Status__c);
        List<Task> tasks = [SELECT Subject, OwnerId FROM Task WHERE WhatId = :inv.Id];
        System.assertEquals(1, tasks.size(), 'One follow-up task for the warehouse manager');
        System.assertEquals(UserInfo.getUserId(), tasks[0].OwnerId);

        update new Inventory__c(Id = inv.Id, On_Hand__c = 4);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :inv.Id], 'No duplicate alert when the status did not change');
    }
}
