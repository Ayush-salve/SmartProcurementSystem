@IsTest
private class RequisitionServiceTest {

    @TestSetup
    static void setupData() {
        Warehouse__c wh = new Warehouse__c(Name = 'Test WH', Warehouse_Code__c = 'TWHRS', Active__c = true);
        insert wh;
        Product2 prod = new Product2(Name = 'Test Product RS', IsActive = true);
        insert prod;
    }

    @IsTest
    static void testSaveNewRequisition() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        Purchase_Requisition__c req = new Purchase_Requisition__c(
            Destination_Warehouse__c = wh.Id,
            Request_Date__c = Date.today(),
            Priority__c = 'Normal'
        );
        Requisition_Line__c line1 = new Requisition_Line__c(
            Product__c = prod.Id,
            Requested_Qty__c = 10,
            Estimated_Unit_Price__c = 100
        );
        Requisition_Line__c line2 = new Requisition_Line__c(
            Product__c = prod.Id,
            Requested_Qty__c = 5,
            Estimated_Unit_Price__c = 200
        );
        Test.startTest();
        Id reqId = RequisitionService.saveRequisition(
            JSON.serialize(req),
            JSON.serialize(new List<Requisition_Line__c>{line1, line2})
        );
        Test.stopTest();
        System.assertNotEquals(null, reqId);
        List<Requisition_Line__c> savedLines = [SELECT Id FROM Requisition_Line__c WHERE Requisition__c = :reqId];
        System.assertEquals(2, savedLines.size(), 'Should have 2 lines');
    }

    @IsTest
    static void testSubmitRequisition() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Purchase_Requisition__c req = new Purchase_Requisition__c(
            Destination_Warehouse__c = wh.Id,
            Request_Date__c = Date.today(),
            Status__c = 'Draft',
            Source__c = 'Manual'
        );
        insert req;
        Test.startTest();
        RequisitionService.submitRequisitionForApproval(req.Id);
        Test.stopTest();
        Purchase_Requisition__c updated = [SELECT Status__c, Submitted_At__c FROM Purchase_Requisition__c WHERE Id = :req.Id];
        System.assertEquals('Submitted', updated.Status__c);
        System.assertNotEquals(null, updated.Submitted_At__c);
    }

    @IsTest
    static void testSubmitNonDraftThrows() {
        Purchase_Requisition__c req = new Purchase_Requisition__c(
            Request_Date__c = Date.today(),
            Status__c = 'Approved',
            Source__c = 'Manual'
        );
        insert req;
        Test.startTest();
        try {
            RequisitionService.submitRequisitionForApproval(req.Id);
            System.assert(false, 'Should have thrown');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Approved'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetRequisitionWithLines() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        Purchase_Requisition__c req = new Purchase_Requisition__c(
            Destination_Warehouse__c = wh.Id, Request_Date__c = Date.today(), Status__c = 'Draft', Source__c = 'Manual'
        );
        insert req;
        Requisition_Line__c line = new Requisition_Line__c(
            Requisition__c = req.Id, Product__c = prod.Id, Requested_Qty__c = 5, Estimated_Unit_Price__c = 50
        );
        insert line;
        Test.startTest();
        RequisitionService.RequisitionWrapper w = RequisitionService.getRequisitionWithLines(req.Id);
        Test.stopTest();
        System.assertNotEquals(null, w);
        System.assertEquals(1, w.lines.size());
    }
}
