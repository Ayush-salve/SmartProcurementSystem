@IsTest
private class PurchaseOrderServiceTest {

    private class DispatchMock implements HttpCalloutMock {
        private final Integer statusCode;
        private final String body;
        DispatchMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }

    @TestSetup
    static void setupData() {
        insert new Warehouse__c(Name = 'PO Test WH', Warehouse_Code__c = 'POWH', Active__c = true);
        insert new Product2(Name = 'PO Test Product', IsActive = true);
        insert new Account(Name = 'PO Test Supplier');
    }

    private static Purchase_Order__c createOrder(String status, Decimal qty, Decimal unitPrice) {
        Purchase_Order__c po = new Purchase_Order__c(
            Supplier__c = [SELECT Id FROM Account LIMIT 1].Id,
            Warehouse__c = [SELECT Id FROM Warehouse__c LIMIT 1].Id,
            Order_Date__c = Date.today(),
            Status__c = status
        );
        insert po;
        if (qty != null) {
            insert new Purchase_Order_Line__c(
                Purchase_Order__c = po.Id, Product__c = [SELECT Id FROM Product2 LIMIT 1].Id,
                Quantity_Ordered__c = qty, Unit_Price__c = unitPrice, Line_Status__c = 'Open'
            );
        }
        return po;
    }

    private static PurchaseOrderService.OrderResult run(Id poId, String operation, String priorStatus) {
        PurchaseOrderService.OrderRequest r = new PurchaseOrderService.OrderRequest();
        r.purchaseOrderId = poId;
        r.operation = operation;
        r.priorStatus = priorStatus;
        return PurchaseOrderService.processFromFlow(new List<PurchaseOrderService.OrderRequest>{ r })[0];
    }

    // ------------------------------------------------------------ Apex service

    @IsTest
    static void testPrepareApprovalRecalculatesSubtotalAndTotal() {
        Purchase_Order__c po = createOrder('Draft', 10, 25);
        update new Purchase_Order__c(Id = po.Id, Tax_Amount__c = 5, Shipping_Amount__c = 10);
        PurchaseOrderService.OrderResult res = run(po.Id, PurchaseOrderService.OP_PREPARE_APPROVAL, null);
        System.assertEquals(true, res.isSuccess, res.message);
        System.assertEquals(265, res.totalAmount);
        System.assertEquals(250, [SELECT Subtotal__c FROM Purchase_Order__c WHERE Id = :po.Id].Subtotal__c);
    }

    @IsTest
    static void testPrepareApprovalRejectsOrdersWithoutLinesOrSupplier() {
        Purchase_Order__c noLines = createOrder('Draft', null, null);
        System.assertEquals(false, run(noLines.Id, PurchaseOrderService.OP_PREPARE_APPROVAL, null).isSuccess);

        Purchase_Order__c noSupplier = createOrder('Draft', 1, 1);
        update new Purchase_Order__c(Id = noSupplier.Id, Supplier__c = null);
        PurchaseOrderService.OrderResult res = run(noSupplier.Id, PurchaseOrderService.OP_PREPARE_APPROVAL, null);
        System.assertEquals(false, res.isSuccess);
        System.assert(res.message.contains('supplier'));
    }

    @IsTest
    static void testDispatchValidationOnlyAllowsApprovedOrders() {
        Purchase_Order__c draft = createOrder('Draft', 1, 1);
        PurchaseOrderService.OrderResult res = run(draft.Id, PurchaseOrderService.OP_DISPATCH, 'Draft');
        System.assertEquals(false, res.isSuccess);
        System.assert(res.message.contains('Sent'), res.message);

        Purchase_Order__c sentNotApproved = createOrder('Sent', 1, 1);
        res = run(sentNotApproved.Id, PurchaseOrderService.OP_DISPATCH, 'Draft');
        System.assertEquals(false, res.isSuccess);
        System.assert(res.message.contains('approved'), res.message);

        System.assertEquals(false, run(draft.Id, 'UNKNOWN', null).isSuccess);
    }

    @IsTest
    static void testAuraSaveAndDispatchGuards() {
        Purchase_Order__c po = createOrder('Approved', 2, 10);
        try {
            PurchaseOrderService.savePurchaseOrder(JSON.serialize(new Purchase_Order__c(Id = po.Id)), '[]');
            System.assert(false, 'Approved orders are not editable');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Cannot edit'), e.getMessage());
        }
        PurchaseOrderService.PurchaseOrderWrapper w = PurchaseOrderService.getPurchaseOrderWithLines(po.Id);
        System.assertEquals(true, w.canDispatch);
        PurchaseOrderService.dispatchPurchaseOrder(po.Id);
        System.assertEquals('Sent', [SELECT Status__c FROM Purchase_Order__c WHERE Id = :po.Id].Status__c);
    }

    // ------------------------------------------------------------ Dispatch flow + queueable

    @IsTest
    static void testDispatchFlowQueuesCalloutAndRecordsSuccess() {
        Purchase_Order__c po = createOrder('Approved', 4, 100);
        Test.setMock(HttpCalloutMock.class, new DispatchMock(201, '{"orderId":"EXT-1001"}'));
        Test.startTest();
        update new Purchase_Order__c(Id = po.Id, Status__c = 'Sent');
        Test.stopTest();

        Purchase_Order__c result = [
            SELECT Status__c, Last_Sync_Status__c, External_Order_Id__c, Idempotency_Key__c, Sent_At__c
            FROM Purchase_Order__c WHERE Id = :po.Id
        ];
        System.assertEquals('Sent', result.Status__c);
        System.assertEquals('Success', result.Last_Sync_Status__c);
        System.assertEquals('EXT-1001', result.External_Order_Id__c);
        System.assertEquals('PO-' + po.Id, result.Idempotency_Key__c);
        System.assertNotEquals(null, result.Sent_At__c);
    }

    @IsTest
    static void testDispatchFailureReturnsOrderToApprovedAndCreatesTask() {
        Purchase_Order__c po = createOrder('Approved', 4, 100);
        Test.setMock(HttpCalloutMock.class, new DispatchMock(500, 'boom'));
        Test.startTest();
        update new Purchase_Order__c(Id = po.Id, Status__c = 'Sent');
        Test.stopTest();

        Purchase_Order__c result = [
            SELECT Status__c, Last_Sync_Status__c, External_Order_Id__c, Sent_At__c FROM Purchase_Order__c WHERE Id = :po.Id
        ];
        System.assertEquals('Approved', result.Status__c);
        System.assertEquals('Failed', result.Last_Sync_Status__c);
        System.assertEquals(null, result.External_Order_Id__c);
        System.assertEquals(null, result.Sent_At__c);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :po.Id], 'Buyer gets a follow-up task');
    }

    @IsTest
    static void testDispatchFlowReturnsOrderWithoutLinesToApproved() {
        Purchase_Order__c po = createOrder('Approved', null, null);
        Test.startTest();
        update new Purchase_Order__c(Id = po.Id, Status__c = 'Sent');
        Test.stopTest();
        Purchase_Order__c result = [SELECT Status__c, Last_Sync_Status__c FROM Purchase_Order__c WHERE Id = :po.Id];
        System.assertEquals('Approved', result.Status__c);
        System.assertEquals('Failed', result.Last_Sync_Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :po.Id]);
    }

    @IsTest
    static void testAlreadyDispatchedOrderIsNotDispatchedAgain() {
        Purchase_Order__c po = createOrder('Approved', 1, 10);
        update new Purchase_Order__c(Id = po.Id, External_Order_Id__c = 'EXT-OLD');
        Test.setMock(HttpCalloutMock.class, new DispatchMock(201, '{"orderId":"EXT-NEW"}'));
        Test.startTest();
        update new Purchase_Order__c(Id = po.Id, Status__c = 'Sent');
        Test.stopTest();
        System.assertEquals('EXT-OLD', [SELECT External_Order_Id__c FROM Purchase_Order__c WHERE Id = :po.Id].External_Order_Id__c);
    }

    // ------------------------------------------------------------ Approval routing flow

    @IsTest
    static void testApprovalRoutingUsesCustomMetadataThresholds() {
        ProcurementTestUtil.addCurrentUserToQueues(new List<String>{ 'Procurement_Approvers', 'Procurement_Managers', 'Finance_Approvers' });
        Purchase_Order__c low = createOrder('Draft', 10, 500);        // 5,000
        Purchase_Order__c mid = createOrder('Draft', 10, 2000);       // 20,000
        Purchase_Order__c high = createOrder('Draft', 1, 150000);     // 150,000

        Test.startTest();
        update new List<Purchase_Order__c>{
            new Purchase_Order__c(Id = low.Id, Status__c = 'Pending Approval'),
            new Purchase_Order__c(Id = mid.Id, Status__c = 'Pending Approval'),
            new Purchase_Order__c(Id = high.Id, Status__c = 'Pending Approval')
        };
        Test.stopTest();

        System.assertEquals('PO_Approval_Level_1', ProcurementTestUtil.processNameFor(low.Id));
        System.assertEquals('PO_Approval_Level_2', ProcurementTestUtil.processNameFor(mid.Id));
        System.assertEquals('PO_Approval_Level_3', ProcurementTestUtil.processNameFor(high.Id));
        System.assertEquals(5000, [SELECT Subtotal__c FROM Purchase_Order__c WHERE Id = :low.Id].Subtotal__c);
    }

    @IsTest
    static void testHighValueOrderNeedsManagerThenFinance() {
        ProcurementTestUtil.addCurrentUserToQueues(new List<String>{ 'Procurement_Managers', 'Finance_Approvers' });
        Purchase_Order__c po = createOrder('Draft', 1, 150000);
        update new Purchase_Order__c(Id = po.Id, Status__c = 'Pending Approval');

        ProcurementTestUtil.decide(po.Id, 'Approve', 'Manager OK');
        System.assertEquals('Pending Approval', [SELECT Status__c FROM Purchase_Order__c WHERE Id = :po.Id].Status__c, 'Finance step still pending');

        Test.startTest();
        ProcurementTestUtil.decide(po.Id, 'Approve', 'Finance OK');
        Test.stopTest();
        System.assertEquals('Approved', [SELECT Status__c FROM Purchase_Order__c WHERE Id = :po.Id].Status__c);
    }

    @IsTest
    static void testRejectedOrderReturnsToDraftAndNotifiesBuyer() {
        ProcurementTestUtil.addCurrentUserToQueues(new List<String>{ 'Procurement_Managers' });
        Purchase_Order__c po = createOrder('Draft', 10, 2000);
        update new Purchase_Order__c(Id = po.Id, Status__c = 'Pending Approval');

        Test.startTest();
        ProcurementTestUtil.decide(po.Id, 'Reject', 'Too expensive');
        Test.stopTest();

        System.assertEquals('Draft', [SELECT Status__c FROM Purchase_Order__c WHERE Id = :po.Id].Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :po.Id], 'Buyer gets a follow-up task');
    }

    @IsTest
    static void testInvalidOrderCannotBeSubmittedForApproval() {
        Purchase_Order__c po = createOrder('Draft', null, null);
        try {
            update new Purchase_Order__c(Id = po.Id, Status__c = 'Pending Approval');
            System.assert(false, 'An order without lines must be blocked');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('no active lines'), e.getMessage());
        }
        System.assertEquals('Draft', [SELECT Status__c FROM Purchase_Order__c WHERE Id = :po.Id].Status__c);
    }
}
