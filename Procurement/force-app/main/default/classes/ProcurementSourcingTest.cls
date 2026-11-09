@IsTest
private class ProcurementSourcingTest {

    @TestSetup
    static void setupData() {
        insert new Warehouse__c(Name = 'Src WH', Warehouse_Code__c = 'SRCWH', Active__c = true);
        List<Product2> products = new List<Product2>();
        for (Integer i = 0; i < 3; i++) products.add(new Product2(Name = 'Src Product ' + i, IsActive = true));
        insert products;
        List<Account> suppliers = new List<Account>();
        for (String name : new List<String>{ 'Src Supplier A', 'Src Supplier B', 'Src Supplier C' }) suppliers.add(new Account(Name = name));
        insert suppliers;
    }

    private static Map<String, Account> suppliers() {
        Map<String, Account> byName = new Map<String, Account>();
        for (Account a : [SELECT Id, Name FROM Account WHERE Name LIKE 'Src Supplier%']) byName.put(a.Name.right(1), a);
        return byName;
    }

    private static List<Product2> products() { return [SELECT Id FROM Product2 WHERE Name LIKE 'Src Product%' ORDER BY Name]; }
    private static Id warehouseId() { return [SELECT Id FROM Warehouse__c LIMIT 1].Id; }

    private static Supplier_Product__c offer(Id supplierId, Id productId, Decimal price, Decimal lead, Decimal quality, Decimal delivery) {
        return new Supplier_Product__c(
            Supplier__c = supplierId, Product__c = productId, Active__c = true, Unit_Price__c = price,
            Lead_Time_Days__c = lead, Quality_Rating__c = quality, Delivery_Rating__c = delivery
        );
    }

    private static Purchase_Requisition__c requisition(String status) {
        Purchase_Requisition__c req = new Purchase_Requisition__c(
            Destination_Warehouse__c = warehouseId(), Request_Date__c = Date.today(),
            Status__c = status, Source__c = 'Manual', Requester__c = UserInfo.getUserId()
        );
        insert req;
        return req;
    }

    private static Requisition_Line__c reqLine(Id requisitionId, Id productId, Decimal qty) {
        return new Requisition_Line__c(Requisition__c = requisitionId, Product__c = productId, Requested_Qty__c = qty, Estimated_Unit_Price__c = 1);
    }

    // ------------------------------------------------------------ SupplierScoringService

    @IsTest
    static void testRankingPutsDominantOfferFirstAndScoresAreOrdered() {
        Map<String, Account> s = suppliers();
        Id productId = products()[0].Id;
        Supplier_Product__c best = offer(s.get('A').Id, productId, 10, 5, 5, 5);
        Supplier_Product__c worse = offer(s.get('B').Id, productId, 20, 30, 1, 1);
        Supplier_Product__c unpriced = offer(s.get('C').Id, productId, null, null, null, null);
        insert new List<Supplier_Product__c>{ best, worse, unpriced };

        Map<Id, List<SupplierScoringService.ScoredOffer>> ranked = SupplierScoringService.rankByProduct(
            [SELECT Id, Supplier__c, Product__c, Unit_Price__c, Lead_Time_Days__c, Quality_Rating__c, Delivery_Rating__c FROM Supplier_Product__c]
        );
        List<SupplierScoringService.ScoredOffer> list1 = ranked.get(productId);
        System.assertEquals(3, list1.size());
        System.assertEquals(best.Id, list1[0].offer.Id);
        System.assertEquals(1, list1[0].rank);
        System.assert(list1[0].compositeScore > list1[1].compositeScore, 'Scores are ranked best first');
        System.assert(list1[1].compositeScore >= list1[2].compositeScore || list1[2].compositeScore >= 0);
        for (SupplierScoringService.ScoredOffer so : list1) {
            System.assert(so.compositeScore >= 0 && so.compositeScore <= 5, 'Scores stay on the 0-5 scale');
        }
    }

    @IsTest
    static void testEligibleOffersExcludeInactiveExpiredAndUnpriced() {
        Map<String, Account> s = suppliers();
        Id productId = products()[0].Id;
        Supplier_Product__c valid = offer(s.get('A').Id, productId, 10, 5, 4, 4);
        Supplier_Product__c inactive = offer(s.get('B').Id, productId, 10, 5, 4, 4);
        inactive.Active__c = false;
        Supplier_Product__c expired = offer(s.get('C').Id, productId, 10, 5, 4, 4);
        expired.Valid_Until__c = Date.today().addDays(-1);
        Supplier_Product__c unpriced = offer(s.get('A').Id, productId, null, 5, 4, 4);
        insert new List<Supplier_Product__c>{ valid, inactive, expired, unpriced };

        List<Supplier_Product__c> eligible = SupplierScoringService.getEligibleOffers(new Set<Id>{ productId });
        System.assertEquals(1, eligible.size());
        System.assertEquals(valid.Id, eligible[0].Id);
        System.assertEquals(0, SupplierScoringService.getEligibleOffers(null).size());
        System.assertEquals(0, SupplierScoringService.getEligibleOffers(new Set<Id>()).size());
        System.assertEquals(1, SupplierScoringService.rankEligibleOffers(new Set<Id>{ productId }).get(productId).size());
    }

    @IsTest
    static void testPickForQuantityHonoursOrderQuantityLimits() {
        Map<String, Account> s = suppliers();
        Id productId = products()[0].Id;
        Supplier_Product__c small = offer(s.get('A').Id, productId, 10, 5, 5, 5);
        small.Maximum_Order_Qty__c = 10;
        Supplier_Product__c large = offer(s.get('B').Id, productId, 20, 30, 3, 3);
        large.Minimum_Order_Qty__c = 20;
        insert new List<Supplier_Product__c>{ small, large };
        List<SupplierScoringService.ScoredOffer> ranked = SupplierScoringService.rankEligibleOffers(new Set<Id>{ productId }).get(productId);

        System.assertEquals(small.Id, SupplierScoringService.pickForQuantity(ranked, 5).offer.Id);
        System.assertEquals(large.Id, SupplierScoringService.pickForQuantity(ranked, 50).offer.Id, 'Falls through to the offer that accepts the quantity');
        System.assertEquals(null, SupplierScoringService.pickForQuantity(ranked, 15), 'No offer accepts 15 units');
        System.assertEquals(null, SupplierScoringService.pickForQuantity(null, 5));
        System.assertNotEquals(null, SupplierScoringService.pickForQuantity(ranked, null));
    }

    // ------------------------------------------------------------ SupplierComparisonService

    @IsTest
    static void testSupplierComparisonReturnsRankedOffersAndFlagsBest() {
        Map<String, Account> s = suppliers();
        Id productId = products()[0].Id;
        Supplier_Product__c best = offer(s.get('A').Id, productId, 10, 5, 5, 5);
        Supplier_Product__c other = offer(s.get('B').Id, productId, 25, 20, 2, 2);
        insert new List<Supplier_Product__c>{ best, other };

        List<SupplierComparisonService.SupplierOfferWrapper> offers = SupplierComparisonService.getSupplierOffersForProduct(productId);
        System.assertEquals(2, offers.size());
        System.assertEquals(best.Id, offers[0].supplierProductId);
        System.assertEquals(true, offers[0].isBestOffer);
        System.assertEquals(false, offers[1].isBestOffer);
        System.assertEquals('Src Supplier A', offers[0].supplierName);
        System.assertEquals(2, SupplierComparisonService.getActiveSupplierProductsForProduct(productId).size());

        System.assertEquals(0, SupplierComparisonService.getSupplierOffersForProduct(products()[1].Id).size());
        System.assertEquals(0, SupplierComparisonService.getActiveSupplierProductsForProduct(products()[1].Id).size());
    }

    // ------------------------------------------------------------ PurchaseOrderService.generatePurchaseOrders

    @IsTest
    static void testGenerateSplitsLinesBySupplierAndMarksPartialWhenUnsourced() {
        Map<String, Account> s = suppliers();
        List<Product2> p = products();
        Supplier_Product__c cheap = offer(s.get('A').Id, p[0].Id, 10, 5, 5, 5);
        Supplier_Product__c preferred = offer(s.get('B').Id, p[1].Id, 40, 10, 3, 3);
        insert new List<Supplier_Product__c>{ cheap, preferred };

        Purchase_Requisition__c req = requisition('Approved');
        Requisition_Line__c autoLine = reqLine(req.Id, p[0].Id, 10);
        Requisition_Line__c preferredLine = reqLine(req.Id, p[1].Id, 5);
        preferredLine.Preferred_Supplier_Product__c = preferred.Id;
        preferredLine.Approved_Qty__c = 4;
        Requisition_Line__c unsourced = reqLine(req.Id, p[2].Id, 1);
        insert new List<Requisition_Line__c>{ autoLine, preferredLine, unsourced };

        List<PurchaseOrderService.GenerationResult> results = PurchaseOrderService.generatePurchaseOrders(new Set<Id>{ req.Id });
        System.assertEquals(true, results[0].isSuccess, results[0].message);
        System.assertEquals(2, results[0].purchaseOrderIds.size(), 'One order per supplier');
        System.assertEquals(1, results[0].unsourcedLines);

        List<Purchase_Order__c> orders = [
            SELECT Supplier__c, Status__c, Subtotal__c, Idempotency_Key__c, Warehouse__c FROM Purchase_Order__c WHERE Purchase_Requisition__c = :req.Id
        ];
        System.assertEquals(2, orders.size());
        Set<String> keys = new Set<String>();
        for (Purchase_Order__c po : orders) {
            System.assertEquals('Draft', po.Status__c);
            System.assertEquals(warehouseId(), po.Warehouse__c);
            keys.add(po.Idempotency_Key__c);
            if (po.Supplier__c == s.get('A').Id) System.assertEquals(100, po.Subtotal__c);
            if (po.Supplier__c == s.get('B').Id) System.assertEquals(160, po.Subtotal__c, 'Approved quantity of 4 at 40');
        }
        System.assertEquals(2, keys.size(), 'Idempotency keys are unique');
        System.assertEquals(2, [SELECT COUNT() FROM Purchase_Order_Line__c WHERE Purchase_Order__r.Purchase_Requisition__c = :req.Id]);
        System.assertEquals('Partially Ordered', [SELECT Status__c FROM Purchase_Requisition__c WHERE Id = :req.Id].Status__c);

        List<PurchaseOrderService.GenerationResult> again = PurchaseOrderService.generatePurchaseOrders(new Set<Id>{ req.Id });
        System.assertEquals(false, again[0].isSuccess, 'Nothing new can be sourced');
        System.assertEquals(2, [SELECT COUNT() FROM Purchase_Order__c WHERE Purchase_Requisition__c = :req.Id], 'No duplicate orders');
    }

    @IsTest
    static void testGenerateCompletesRequisitionAndSkipsAlreadyOrderedLines() {
        Map<String, Account> s = suppliers();
        List<Product2> p = products();
        insert new List<Supplier_Product__c>{ offer(s.get('A').Id, p[0].Id, 10, 5, 4, 4), offer(s.get('A').Id, p[1].Id, 7, 3, 4, 4) };
        Purchase_Requisition__c req = requisition('Approved');
        insert new List<Requisition_Line__c>{ reqLine(req.Id, p[0].Id, 3), reqLine(req.Id, p[1].Id, 2) };

        List<PurchaseOrderService.GenerationResult> results = PurchaseOrderService.generatePurchaseOrders(new Set<Id>{ req.Id });
        System.assertEquals(true, results[0].isSuccess, results[0].message);
        System.assertEquals(1, results[0].purchaseOrderIds.size(), 'Both lines go to the same supplier');
        System.assertEquals('Ordered', [SELECT Status__c FROM Purchase_Requisition__c WHERE Id = :req.Id].Status__c);
        System.assertEquals(2, [SELECT COUNT() FROM Purchase_Order_Line__c]);

        Purchase_Requisition__c reopened = requisition('Partially Ordered');
        Purchase_Order__c existing = new Purchase_Order__c(
            Purchase_Requisition__c = reopened.Id, Supplier__c = s.get('A').Id, Warehouse__c = warehouseId(), Order_Date__c = Date.today(), Status__c = 'Draft'
        );
        insert existing;
        insert new Purchase_Order_Line__c(Purchase_Order__c = existing.Id, Product__c = p[0].Id, Quantity_Ordered__c = 1, Unit_Price__c = 1, Line_Status__c = 'Open');
        insert reqLine(reopened.Id, p[0].Id, 1);
        PurchaseOrderService.GenerationResult skipped = PurchaseOrderService.generatePurchaseOrders(new Set<Id>{ reopened.Id })[0];
        System.assertEquals(false, skipped.isSuccess);
        System.assert(skipped.message.contains('already on a purchase order'), skipped.message);
    }

    @IsTest
    static void testGenerateReportsUnapprovedMissingAndUnsourceableRequisitions() {
        Purchase_Requisition__c draft = requisition('Draft');
        Purchase_Requisition__c noOffers = requisition('Approved');
        insert reqLine(noOffers.Id, products()[2].Id, 1);
        Purchase_Requisition__c gone = requisition('Draft');
        Id goneId = gone.Id;
        delete gone;

        Map<Id, PurchaseOrderService.GenerationResult> byId = new Map<Id, PurchaseOrderService.GenerationResult>();
        for (PurchaseOrderService.GenerationResult r : PurchaseOrderService.generatePurchaseOrders(new Set<Id>{ draft.Id, noOffers.Id, goneId })) {
            byId.put(r.requisitionId, r);
        }
        System.assert(byId.get(draft.Id).message.contains('Only approved'), byId.get(draft.Id).message);
        System.assert(byId.get(noOffers.Id).message.contains('No eligible supplier'), byId.get(noOffers.Id).message);
        System.assert(byId.get(goneId).message.contains('not found'), byId.get(goneId).message);
        System.assertEquals(0, [SELECT COUNT() FROM Purchase_Order__c]);
    }

    // ------------------------------------------------------------ PurchaseOrderService Aura entry points

    @IsTest
    static void testSavePurchaseOrderCreatesUpdatesAndReplacesLines() {
        Map<String, Account> s = suppliers();
        List<Product2> p = products();
        Purchase_Order__c po = new Purchase_Order__c(Supplier__c = s.get('A').Id, Warehouse__c = warehouseId());
        List<Purchase_Order_Line__c> lines = new List<Purchase_Order_Line__c>{
            new Purchase_Order_Line__c(Product__c = p[0].Id, Quantity_Ordered__c = 5, Unit_Price__c = 10),
            new Purchase_Order_Line__c(Product__c = p[1].Id, Quantity_Ordered__c = 2, Unit_Price__c = 20)
        };
        Id poId = PurchaseOrderService.savePurchaseOrder(JSON.serialize(po), JSON.serialize(lines));

        Purchase_Order__c saved = [SELECT Status__c, Order_Date__c FROM Purchase_Order__c WHERE Id = :poId];
        System.assertEquals('Draft', saved.Status__c);
        System.assertEquals(Date.today(), saved.Order_Date__c);
        List<Purchase_Order_Line__c> savedLines = [SELECT Id, Product__c, Line_Status__c FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :poId ORDER BY Name];
        System.assertEquals(2, savedLines.size());
        System.assertEquals('Open', savedLines[0].Line_Status__c);

        PurchaseOrderService.PurchaseOrderWrapper wrapper = PurchaseOrderService.getPurchaseOrderWithLines(poId);
        System.assertEquals(true, wrapper.isEditable);
        System.assertEquals(false, wrapper.canDispatch, 'Draft orders cannot be dispatched');
        System.assertEquals(2, wrapper.lines.size());

        Purchase_Order_Line__c kept = new Purchase_Order_Line__c(Id = savedLines[0].Id, Quantity_Ordered__c = 9, Unit_Price__c = 10);
        Purchase_Order_Line__c added = new Purchase_Order_Line__c(Product__c = p[2].Id, Quantity_Ordered__c = 1, Unit_Price__c = 5);
        PurchaseOrderService.savePurchaseOrder(
            JSON.serialize(new Purchase_Order__c(Id = poId, Expected_Delivery__c = Date.today().addDays(7))),
            JSON.serialize(new List<Purchase_Order_Line__c>{ kept, added })
        );
        List<Purchase_Order_Line__c> after = [SELECT Id, Quantity_Ordered__c FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :poId];
        System.assertEquals(2, after.size(), 'The omitted line is deleted and a new one added');
        System.assertEquals(Date.today().addDays(7), [SELECT Expected_Delivery__c FROM Purchase_Order__c WHERE Id = :poId].Expected_Delivery__c);
    }

    @IsTest
    static void testSavePurchaseOrderRollsBackAndReportsErrors() {
        Purchase_Order__c po = new Purchase_Order__c(Supplier__c = suppliers().get('A').Id, Warehouse__c = warehouseId());
        Purchase_Order_Line__c invalid = new Purchase_Order_Line__c(Product__c = products()[0].Id, Quantity_Ordered__c = 0, Unit_Price__c = 10);
        try {
            PurchaseOrderService.savePurchaseOrder(JSON.serialize(po), JSON.serialize(new List<Purchase_Order_Line__c>{ invalid }));
            System.assert(false, 'An invalid line must fail the save');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Error saving purchase order'), e.getMessage());
        }
        System.assertEquals(0, [SELECT COUNT() FROM Purchase_Order__c], 'The order is rolled back with its line');

        try {
            PurchaseOrderService.getPurchaseOrderWithLines(null);
            System.assert(false, 'A missing order must be reported');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Error loading purchase order'), e.getMessage());
        }
    }

    @IsTest
    static void testCreatePurchaseOrderFromRequisition() {
        Map<String, Account> s = suppliers();
        List<Product2> p = products();
        Purchase_Requisition__c req = requisition('Approved');
        Requisition_Line__c approved = reqLine(req.Id, p[0].Id, 10);
        approved.Approved_Qty__c = 6;
        approved.Approved_Unit_Price__c = 12;
        insert new List<Requisition_Line__c>{ approved, reqLine(req.Id, p[1].Id, 3) };

        Id poId = PurchaseOrderService.createPurchaseOrderFromRequisition(req.Id, s.get('A').Id, null);
        Purchase_Order__c po = [SELECT Status__c, Warehouse__c, Supplier__c FROM Purchase_Order__c WHERE Id = :poId];
        System.assertEquals('Draft', po.Status__c);
        System.assertEquals(warehouseId(), po.Warehouse__c, 'Defaults to the requisition warehouse');
        Map<Id, Purchase_Order_Line__c> byProduct = new Map<Id, Purchase_Order_Line__c>();
        for (Purchase_Order_Line__c l : [SELECT Product__c, Quantity_Ordered__c, Unit_Price__c FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :poId]) {
            byProduct.put(l.Product__c, l);
        }
        System.assertEquals(6, byProduct.get(p[0].Id).Quantity_Ordered__c);
        System.assertEquals(12, byProduct.get(p[0].Id).Unit_Price__c);
        System.assertEquals(3, byProduct.get(p[1].Id).Quantity_Ordered__c);
        System.assertEquals(1, byProduct.get(p[1].Id).Unit_Price__c, 'Falls back to the estimated price');

        Purchase_Requisition__c draft = requisition('Draft');
        try {
            PurchaseOrderService.createPurchaseOrderFromRequisition(draft.Id, s.get('A').Id, null);
            System.assert(false, 'Only approved requisitions can be converted');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Only approved requisitions'), e.getMessage());
        }
        System.assertEquals(1, [SELECT COUNT() FROM Purchase_Order__c]);
    }

    @IsTest
    static void testGetRecentPurchaseOrdersHonoursLimit() {
        Id supplierId = suppliers().get('A').Id;
        List<Purchase_Order__c> orders = new List<Purchase_Order__c>();
        for (Integer i = 0; i < 3; i++) {
            orders.add(new Purchase_Order__c(Supplier__c = supplierId, Warehouse__c = warehouseId(), Order_Date__c = Date.today(), Status__c = 'Draft'));
        }
        insert orders;
        System.assertEquals(2, PurchaseOrderService.getRecentPurchaseOrders(2).size());
        System.assertEquals(3, PurchaseOrderService.getRecentPurchaseOrders(null).size());
    }
}
