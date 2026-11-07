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

    private static Purchase_Requisition__c createRequisitionWithLine(Decimal qty, Decimal price) {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        Purchase_Requisition__c req = new Purchase_Requisition__c(
            Destination_Warehouse__c = wh.Id,
            Request_Date__c = Date.today(),
            Status__c = 'Draft',
            Source__c = 'Manual',
            Requester__c = UserInfo.getUserId()
        );
        insert req;
        insert new Requisition_Line__c(
            Requisition__c = req.Id, Product__c = prod.Id, Requested_Qty__c = qty, Estimated_Unit_Price__c = price
        );
        return req;
    }

    @IsTest
    static void testSubmitRequisition() {
        ProcurementTestUtil.addCurrentUserToQueues(new List<String>{ 'Procurement_Approvers' });
        Purchase_Requisition__c req = createRequisitionWithLine(10, 25);
        Test.startTest();
        RequisitionService.submitRequisitionForApproval(req.Id);
        Test.stopTest();
        Purchase_Requisition__c updated = [
            SELECT Status__c, Submitted_At__c, Estimated_Total__c, Approval_Required__c
            FROM Purchase_Requisition__c WHERE Id = :req.Id
        ];
        System.assertEquals('Under Review', updated.Status__c, 'Approval should have started');
        System.assertNotEquals(null, updated.Submitted_At__c);
        System.assertEquals(250, updated.Estimated_Total__c);
        System.assertEquals(true, updated.Approval_Required__c);
        System.assertEquals('Requisition_Approval', ProcurementTestUtil.processNameFor(req.Id));
    }

    @IsTest
    static void testSubmitWithoutLinesIsBlockedByFlow() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Purchase_Requisition__c req = new Purchase_Requisition__c(
            Destination_Warehouse__c = wh.Id, Request_Date__c = Date.today(), Status__c = 'Draft', Source__c = 'Manual'
        );
        insert req;
        try {
            RequisitionService.submitRequisitionForApproval(req.Id);
            System.assert(false, 'Submitting a requisition without lines must fail');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('at least one requisition line'), e.getMessage());
        }
        System.assertEquals('Draft', [SELECT Status__c FROM Purchase_Requisition__c WHERE Id = :req.Id].Status__c);
    }

    @IsTest
    static void testValidationInvocableChecksLinesAndTotals() {
        Purchase_Requisition__c valid = createRequisitionWithLine(4, 50);
        Purchase_Requisition__c empty = new Purchase_Requisition__c(Request_Date__c = Date.today(), Status__c = 'Draft');
        insert empty;
        List<RequisitionService.SubmissionRequest> requests = new List<RequisitionService.SubmissionRequest>();
        for (Id reqId : new List<Id>{ valid.Id, empty.Id }) {
            RequisitionService.SubmissionRequest r = new RequisitionService.SubmissionRequest();
            r.requisitionId = reqId;
            requests.add(r);
        }
        List<RequisitionService.SubmissionResult> results = RequisitionService.validateForSubmission(requests);
        System.assertEquals(true, results[0].isValid);
        System.assertEquals(200, results[0].estimatedTotal);
        System.assertEquals(1, results[0].lineCount);
        System.assertEquals(false, results[1].isValid);
        System.assertEquals(0, results[1].lineCount);
    }

    @IsTest
    static void testApprovalCompletesRequisitionAndNotifiesRequester() {
        ProcurementTestUtil.addCurrentUserToQueues(new List<String>{ 'Procurement_Approvers' });
        Purchase_Requisition__c req = createRequisitionWithLine(2, 100);
        RequisitionService.submitRequisitionForApproval(req.Id);

        Test.startTest();
        ProcurementTestUtil.decide(req.Id, 'Approve', 'Looks fine');
        Test.stopTest();

        Purchase_Requisition__c approved = [
            SELECT Status__c, Approved_At__c, Approved_Total__c FROM Purchase_Requisition__c WHERE Id = :req.Id
        ];
        System.assertEquals('Approved', approved.Status__c);
        System.assertNotEquals(null, approved.Approved_At__c);
        System.assertEquals(200, approved.Approved_Total__c);
    }

    @IsTest
    static void testRejectionRecordsReasonAndCreatesFollowUpTask() {
        ProcurementTestUtil.addCurrentUserToQueues(new List<String>{ 'Procurement_Approvers' });
        Purchase_Requisition__c req = createRequisitionWithLine(2, 100);
        RequisitionService.submitRequisitionForApproval(req.Id);

        Test.startTest();
        ProcurementTestUtil.decide(req.Id, 'Reject', 'Over budget');
        Test.stopTest();

        Purchase_Requisition__c rejected = [SELECT Status__c, Rejection_Reason__c FROM Purchase_Requisition__c WHERE Id = :req.Id];
        System.assertEquals('Rejected', rejected.Status__c);
        System.assertNotEquals(null, rejected.Rejection_Reason__c);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :req.Id], 'Requester gets a follow-up task');
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
