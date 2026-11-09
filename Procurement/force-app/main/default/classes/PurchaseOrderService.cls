public with sharing class PurchaseOrderService {

    public class PurchaseOrderWrapper {
        @AuraEnabled public Purchase_Order__c order;
        @AuraEnabled public List<Purchase_Order_Line__c> lines;
        @AuraEnabled public Boolean isEditable;
        @AuraEnabled public Boolean canDispatch;
    }

    private static final Set<String> EDITABLE_STATUSES = new Set<String>{'Draft', 'Pending Approval'};

    public static final String OP_PREPARE_APPROVAL = 'PREPARE_APPROVAL';
    public static final String OP_DISPATCH = 'DISPATCH';

    // Raised only by ProcurementDispatchQueueable while it records a supplier-confirmed dispatch, so that
    // PurchaseOrderTrigger can reject any other attempt to set Status = Sent.
    public static Boolean dispatchConfirmationInProgress = false;

    public class OrderRequest {
        @InvocableVariable(label='Purchase Order Id' required=true)
        public Id purchaseOrderId;
        @InvocableVariable(label='Operation (PREPARE_APPROVAL or DISPATCH)' required=true)
        public String operation;
    }

    public class OrderResult {
        @InvocableVariable(label='Purchase Order Id')
        public Id purchaseOrderId;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Message')
        public String message;
        @InvocableVariable(label='Total Amount')
        public Decimal totalAmount;
    }

    // PREPARE_APPROVAL validates the order and recalculates Subtotal from its lines so approval routing
    // uses an authoritative amount. DISPATCH validates an approved order whose dispatch was requested
    // (Last_Sync_Status = Pending) and queues the asynchronous external dispatch; the order only becomes
    // Sent once the supplier confirms it.
    @InvocableMethod(
        label='Process Purchase Order'
        description='Validates purchase orders for approval or dispatch. Returns a result per order instead of throwing; dispatch is performed asynchronously.'
    )
    public static List<OrderResult> processFromFlow(List<OrderRequest> requests) {
        Set<Id> ids = new Set<Id>();
        for (OrderRequest r : requests) {
            if (r.purchaseOrderId != null) ids.add(r.purchaseOrderId);
        }
        Map<Id, Purchase_Order__c> poMap = new Map<Id, Purchase_Order__c>([
            SELECT Id, Status__c, Supplier__c, Subtotal__c, Tax_Amount__c, Shipping_Amount__c,
                   External_Order_Id__c, Idempotency_Key__c, Last_Sync_Status__c,
                   (SELECT Id, Product__c, Quantity_Ordered__c, Unit_Price__c, Line_Total__c, Line_Status__c
                    FROM Purchase_Order_Lines__r WHERE Line_Status__c != 'Cancelled')
            FROM Purchase_Order__c WHERE Id IN :ids WITH USER_MODE
        ]);

        List<OrderResult> results = new List<OrderResult>();
        Map<Id, Purchase_Order__c> toUpdate = new Map<Id, Purchase_Order__c>();
        List<Id> toDispatch = new List<Id>();

        for (OrderRequest r : requests) {
            OrderResult res = new OrderResult();
            res.purchaseOrderId = r.purchaseOrderId;
            res.isSuccess = false;
            Purchase_Order__c po = poMap.get(r.purchaseOrderId);
            if (po == null) {
                res.message = 'Purchase order not found or not accessible.';
                results.add(res);
                continue;
            }
            Decimal subtotal = 0;
            for (Purchase_Order_Line__c line : po.Purchase_Order_Lines__r) {
                subtotal += line.Line_Total__c == null ? 0 : line.Line_Total__c;
            }
            res.totalAmount = subtotal + nz(po.Tax_Amount__c) + nz(po.Shipping_Amount__c);

            String error = validateOrderContent(po);
            if (error == null && r.operation == OP_DISPATCH) {
                error = validateDispatch(po);
            } else if (error == null && r.operation != OP_PREPARE_APPROVAL) {
                error = 'Unsupported operation: ' + r.operation;
            }

            if (error != null) {
                res.message = error;
            } else {
                res.isSuccess = true;
                res.message = 'Validation passed.';
                Purchase_Order__c upd = toUpdate.containsKey(po.Id) ? toUpdate.get(po.Id) : new Purchase_Order__c(Id = po.Id);
                if (po.Subtotal__c != subtotal) upd.Subtotal__c = subtotal;
                if (r.operation == OP_DISPATCH && !toDispatch.contains(po.Id)) {
                    if (String.isBlank(po.Idempotency_Key__c)) upd.Idempotency_Key__c = 'PO-' + po.Id;
                    toDispatch.add(po.Id);
                    res.message = 'Dispatch queued.';
                }
                toUpdate.put(po.Id, upd);
            }
            results.add(res);
        }

        if (!toUpdate.isEmpty()) {
            // System-maintained total and integration fields; read access to the order was verified above.
            update toUpdate.values();
        }
        if (!toDispatch.isEmpty()) {
            System.enqueueJob(new ProcurementDispatchQueueable(toDispatch, 1));
        }
        return results;
    }

    private static String validateOrderContent(Purchase_Order__c po) {
        if (po.Supplier__c == null) {
            return 'A supplier is required on the purchase order.';
        }
        if (po.Purchase_Order_Lines__r.isEmpty()) {
            return 'The purchase order has no active lines.';
        }
        for (Purchase_Order_Line__c line : po.Purchase_Order_Lines__r) {
            if (line.Product__c == null) {
                return 'Every purchase order line must have a product.';
            }
            if (line.Quantity_Ordered__c == null || line.Quantity_Ordered__c <= 0) {
                return 'Every purchase order line must have a quantity greater than zero.';
            }
            if (line.Unit_Price__c == null || line.Unit_Price__c < 0) {
                return 'Every purchase order line must have a valid unit price.';
            }
        }
        return null;
    }

    private static String validateDispatch(Purchase_Order__c po) {
        if (po.Status__c != 'Approved') {
            return 'Only an approved purchase order can be dispatched. Current status: ' + po.Status__c;
        }
        if (String.isNotBlank(po.External_Order_Id__c)) {
            return 'This purchase order has already been dispatched.';
        }
        if (po.Last_Sync_Status__c != 'Pending') {
            return 'Dispatch has not been requested for this purchase order.';
        }
        return null;
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    // ---------------------------------------------------------------- Dispatch request

    // Starts a dispatch by moving Last_Sync_Status__c to Pending on approved orders. The
    // Purchase_Order_Dispatch flow reacts to that change and queues the callout, so there is a single
    // dispatch path for the LWC, Flow and Agentforce. Returns an error message per order that was rejected.
    public static Map<Id, String> requestDispatch(Set<Id> orderIds) {
        Map<Id, String> errors = new Map<Id, String>();
        if (!Schema.sObjectType.Purchase_Order__c.isUpdateable()) {
            for (Id orderId : orderIds) errors.put(orderId, 'You do not have permission to dispatch purchase orders.');
            return errors;
        }
        Map<Id, Purchase_Order__c> poMap = new Map<Id, Purchase_Order__c>([
            SELECT Id, Status__c, Supplier__c, External_Order_Id__c, Last_Sync_Status__c,
                   (SELECT Id, Product__c, Quantity_Ordered__c, Unit_Price__c FROM Purchase_Order_Lines__r WHERE Line_Status__c != 'Cancelled')
            FROM Purchase_Order__c WHERE Id IN :orderIds WITH USER_MODE
        ]);

        List<Purchase_Order__c> updates = new List<Purchase_Order__c>();
        for (Id orderId : orderIds) {
            Purchase_Order__c po = poMap.get(orderId);
            String error;
            if (po == null) {
                error = 'Purchase order not found or not accessible.';
            } else if (po.Status__c != 'Approved') {
                error = 'Purchase order must be Approved before dispatching. Current status: ' + po.Status__c;
            } else if (String.isNotBlank(po.External_Order_Id__c)) {
                error = 'This purchase order has already been dispatched.';
            } else if (po.Last_Sync_Status__c == 'Pending') {
                error = 'A dispatch is already in progress for this purchase order.';
            } else {
                error = validateOrderContent(po);
            }
            if (error != null) {
                errors.put(orderId, error);
            } else {
                updates.add(new Purchase_Order__c(
                    Id = orderId, Last_Sync_Status__c = 'Pending', Dispatch_Attempts__c = 0, Last_Sync_Error__c = null
                ));
            }
        }
        if (!updates.isEmpty()) {
            // Integration bookkeeping fields are system-maintained; update access was checked above.
            update updates;
        }
        return errors;
    }

    // ---------------------------------------------------------------- Generation from requisitions

    public class GenerationResult {
        public Id requisitionId;
        public Boolean isSuccess = false;
        public String message;
        public List<Id> purchaseOrderIds = new List<Id>();
        public Integer unsourcedLines = 0;
    }

    private class LineSourcing {
        Requisition_Line__c line;
        Supplier_Product__c offer;
        Decimal quantity;
    }

    // Creates draft purchase orders (one per supplier) with their lines from approved requisitions. Each
    // line is sourced from its preferred supplier product, otherwise from the best-ranked eligible offer
    // (SupplierScoringService). Lines whose product is already on a live order for the requisition are
    // skipped, so running it twice does not create duplicates. All DML shares one savepoint.
    public static List<GenerationResult> generatePurchaseOrders(Set<Id> requisitionIds) {
        Map<Id, GenerationResult> results = new Map<Id, GenerationResult>();
        for (Id requisitionId : requisitionIds) {
            GenerationResult res = new GenerationResult();
            res.requisitionId = requisitionId;
            results.put(requisitionId, res);
        }
        if (!Schema.sObjectType.Purchase_Order__c.isCreateable() || !Schema.sObjectType.Purchase_Order_Line__c.isCreateable()) {
            for (GenerationResult res : results.values()) res.message = 'You do not have permission to create purchase orders.';
            return results.values();
        }

        Map<Id, Purchase_Requisition__c> requisitions = new Map<Id, Purchase_Requisition__c>([
            SELECT Id, Status__c, Destination_Warehouse__c,
                   (SELECT Id, Product__c, Requested_Qty__c, Approved_Qty__c, Preferred_Supplier_Product__c
                    FROM Requisition_Lines__r)
            FROM Purchase_Requisition__c WHERE Id IN :requisitionIds WITH USER_MODE
        ]);

        Map<Id, Set<Id>> orderedProducts = new Map<Id, Set<Id>>();
        for (Purchase_Order_Line__c existing : [
            SELECT Product__c, Purchase_Order__r.Purchase_Requisition__c
            FROM Purchase_Order_Line__c
            WHERE Purchase_Order__r.Purchase_Requisition__c IN :requisitionIds
              AND Purchase_Order__r.Status__c != 'Cancelled' AND Line_Status__c != 'Cancelled'
        ]) {
            Id requisitionId = existing.Purchase_Order__r.Purchase_Requisition__c;
            if (!orderedProducts.containsKey(requisitionId)) orderedProducts.put(requisitionId, new Set<Id>());
            orderedProducts.get(requisitionId).add(existing.Product__c);
        }
        Set<String> usedKeys = new Set<String>();
        for (Purchase_Order__c existing : [
            SELECT Idempotency_Key__c FROM Purchase_Order__c
            WHERE Purchase_Requisition__c IN :requisitionIds AND Idempotency_Key__c != null
        ]) {
            usedKeys.add(existing.Idempotency_Key__c);
        }

        Set<Id> productIds = new Set<Id>();
        Set<Id> preferredIds = new Set<Id>();
        for (Purchase_Requisition__c req : requisitions.values()) {
            for (Requisition_Line__c line : req.Requisition_Lines__r) {
                if (line.Product__c != null) productIds.add(line.Product__c);
                if (line.Preferred_Supplier_Product__c != null) preferredIds.add(line.Preferred_Supplier_Product__c);
            }
        }
        Map<Id, List<SupplierScoringService.ScoredOffer>> ranked = SupplierScoringService.rankEligibleOffers(productIds);
        Map<Id, Supplier_Product__c> preferred = new Map<Id, Supplier_Product__c>(
            preferredIds.isEmpty() ? new List<Supplier_Product__c>() : [
                SELECT Id, Supplier__c, Product__c, Unit_Price__c, Lead_Time_Days__c, Active__c, Valid_Until__c
                FROM Supplier_Product__c WHERE Id IN :preferredIds WITH USER_MODE
            ]
        );

        // supplier groups: requisition Id -> supplier Id -> lines
        Map<Id, Map<Id, List<LineSourcing>>> plan = new Map<Id, Map<Id, List<LineSourcing>>>();
        for (Id requisitionId : requisitionIds) {
            GenerationResult res = results.get(requisitionId);
            Purchase_Requisition__c req = requisitions.get(requisitionId);
            if (req == null) {
                res.message = 'Requisition not found or not accessible.';
                continue;
            }
            if (req.Status__c != 'Approved' && req.Status__c != 'Partially Ordered') {
                res.message = 'Only approved requisitions can be converted to purchase orders. Current status: ' + req.Status__c;
                continue;
            }
            Set<Id> alreadyOrdered = orderedProducts.containsKey(requisitionId) ? orderedProducts.get(requisitionId) : new Set<Id>();
            Map<Id, List<LineSourcing>> bySupplier = new Map<Id, List<LineSourcing>>();
            Integer remaining = 0;
            for (Requisition_Line__c line : req.Requisition_Lines__r) {
                if (alreadyOrdered.contains(line.Product__c)) continue;
                remaining++;
                LineSourcing sourcing = new LineSourcing();
                sourcing.line = line;
                sourcing.quantity = line.Approved_Qty__c != null && line.Approved_Qty__c > 0 ? line.Approved_Qty__c : line.Requested_Qty__c;
                Supplier_Product__c pref = line.Preferred_Supplier_Product__c == null ? null : preferred.get(line.Preferred_Supplier_Product__c);
                if (pref != null && pref.Active__c && pref.Unit_Price__c != null
                    && (pref.Valid_Until__c == null || pref.Valid_Until__c >= Date.today())) {
                    sourcing.offer = pref;
                } else {
                    SupplierScoringService.ScoredOffer best = SupplierScoringService.pickForQuantity(ranked.get(line.Product__c), sourcing.quantity);
                    if (best != null) sourcing.offer = best.offer;
                }
                if (sourcing.offer == null) {
                    res.unsourcedLines++;
                    continue;
                }
                Id supplierId = sourcing.offer.Supplier__c;
                if (!bySupplier.containsKey(supplierId)) bySupplier.put(supplierId, new List<LineSourcing>());
                bySupplier.get(supplierId).add(sourcing);
            }
            if (remaining == 0) {
                res.message = 'Every line of this requisition is already on a purchase order.';
            } else if (bySupplier.isEmpty()) {
                res.message = 'No eligible supplier offer was found for the remaining lines.';
            } else {
                plan.put(requisitionId, bySupplier);
            }
        }
        if (plan.isEmpty()) return results.values();

        Savepoint sp = Database.setSavepoint();
        try {
            List<Purchase_Order__c> orders = new List<Purchase_Order__c>();
            List<List<LineSourcing>> orderLines = new List<List<LineSourcing>>();
            List<Id> orderRequisition = new List<Id>();
            for (Id requisitionId : plan.keySet()) {
                Purchase_Requisition__c req = requisitions.get(requisitionId);
                for (Id supplierId : plan.get(requisitionId).keySet()) {
                    List<LineSourcing> supplierLines = plan.get(requisitionId).get(supplierId);
                    Decimal subtotal = 0;
                    Decimal longestLead = 0;
                    for (LineSourcing ls : supplierLines) {
                        subtotal += ls.quantity * ls.offer.Unit_Price__c;
                        if (ls.offer.Lead_Time_Days__c != null && ls.offer.Lead_Time_Days__c > longestLead) longestLead = ls.offer.Lead_Time_Days__c;
                    }
                    String baseKey = 'REQ-' + requisitionId + '-' + supplierId;
                    String key = baseKey;
                    Integer suffix = 1;
                    while (usedKeys.contains(key)) {
                        key = baseKey + '-' + suffix;
                        suffix++;
                    }
                    usedKeys.add(key);
                    orders.add(new Purchase_Order__c(
                        Purchase_Requisition__c = requisitionId,
                        Supplier__c = supplierId,
                        Warehouse__c = req.Destination_Warehouse__c,
                        Order_Date__c = Date.today(),
                        Expected_Delivery__c = longestLead > 0 ? Date.today().addDays(Integer.valueOf(longestLead)) : null,
                        Status__c = 'Draft',
                        Subtotal__c = subtotal,
                        Idempotency_Key__c = key
                    ));
                    orderLines.add(supplierLines);
                    orderRequisition.add(requisitionId);
                }
            }
            insert orders;

            List<Purchase_Order_Line__c> lines = new List<Purchase_Order_Line__c>();
            for (Integer i = 0; i < orders.size(); i++) {
                results.get(orderRequisition[i]).purchaseOrderIds.add(orders[i].Id);
                for (LineSourcing ls : orderLines[i]) {
                    lines.add(new Purchase_Order_Line__c(
                        Purchase_Order__c = orders[i].Id,
                        Product__c = ls.line.Product__c,
                        Supplier_Product__c = ls.offer.Id,
                        Quantity_Ordered__c = ls.quantity,
                        Unit_Price__c = ls.offer.Unit_Price__c,
                        Line_Status__c = 'Open'
                    ));
                }
            }
            insert lines;

            List<Purchase_Requisition__c> requisitionUpdates = new List<Purchase_Requisition__c>();
            for (Id requisitionId : plan.keySet()) {
                GenerationResult res = results.get(requisitionId);
                Boolean complete = res.unsourcedLines == 0;
                String newStatus = complete ? 'Ordered' : 'Partially Ordered';
                if (newStatus != requisitions.get(requisitionId).Status__c) {
                    requisitionUpdates.add(new Purchase_Requisition__c(Id = requisitionId, Status__c = newStatus));
                }
                res.isSuccess = true;
                res.message = res.purchaseOrderIds.size() + ' purchase order(s) created'
                    + (complete ? '.' : '; ' + res.unsourcedLines + ' line(s) have no eligible supplier and remain to be ordered.');
            }
            if (!requisitionUpdates.isEmpty()) update requisitionUpdates;
        } catch (Exception e) {
            Database.rollback(sp);
            for (Id requisitionId : plan.keySet()) {
                GenerationResult res = results.get(requisitionId);
                res.isSuccess = false;
                res.purchaseOrderIds = new List<Id>();
                res.message = 'Purchase orders could not be created: ' + e.getMessage();
            }
        }
        return results.values();
    }

    // ---------------------------------------------------------------- Trigger rules

    private static final Map<String, Set<String>> ORDER_TRANSITIONS = new Map<String, Set<String>>{
        'Draft' => new Set<String>{'Pending Approval', 'Cancelled'},
        'Pending Approval' => new Set<String>{'Approved', 'Draft', 'Cancelled'},
        'Approved' => new Set<String>{'Sent', 'Partially Received', 'Received', 'Cancelled'},
        'Sent' => new Set<String>{'Acknowledged', 'Partially Received', 'Received', 'Cancelled'},
        'Acknowledged' => new Set<String>{'Partially Received', 'Received', 'Cancelled'},
        'Partially Received' => new Set<String>{'Received'},
        'Received' => new Set<String>(),
        'Cancelled' => new Set<String>()
    };

    // Used by PurchaseOrderTrigger (before update): valid status transitions, Sent only after supplier
    // confirmation, dispatch requests only on approved orders, and no cancellation once goods are
    // received or while a dispatch is in flight.
    public static void enforceOrderRules(List<Purchase_Order__c> newList, Map<Id, Purchase_Order__c> oldMap) {
        Set<Id> cancelling = new Set<Id>();
        for (Purchase_Order__c po : newList) {
            Purchase_Order__c old = oldMap.get(po.Id);
            if (old == null) continue;

            if (po.Status__c != old.Status__c) {
                Set<String> allowed = ORDER_TRANSITIONS.get(String.isBlank(old.Status__c) ? 'Draft' : old.Status__c);
                if (allowed == null || !allowed.contains(po.Status__c)) {
                    po.addError('A purchase order cannot move from ' + old.Status__c + ' to ' + po.Status__c + '.');
                    continue;
                }
                if (po.Status__c == 'Sent' && !(dispatchConfirmationInProgress && String.isNotBlank(po.External_Order_Id__c))) {
                    po.addError('A purchase order becomes Sent only after the supplier confirms the dispatch. Use Dispatch to send an approved order.');
                    continue;
                }
                if (po.Status__c == 'Cancelled') {
                    if (po.Last_Sync_Status__c == 'Pending') {
                        po.addError('A dispatch is in progress for this purchase order. Wait for it to finish before cancelling.');
                        continue;
                    }
                    cancelling.add(po.Id);
                }
            }

            if (po.Last_Sync_Status__c == 'Pending' && old.Last_Sync_Status__c != 'Pending'
                && (po.Status__c != 'Approved' || String.isNotBlank(po.External_Order_Id__c))) {
                po.addError('A dispatch can only be requested for an approved purchase order that has not been dispatched.');
                continue;
            }

            String lockedField = changedFieldAfterDispatch(po, old);
            if (lockedField != null) {
                po.addError(lockedField + ' cannot be changed after the purchase order has been dispatched to the supplier.');
            }
        }

        if (cancelling.isEmpty()) return;
        Set<Id> receivedOrders = new Set<Id>();
        for (Purchase_Order_Line__c line : [
            SELECT Purchase_Order__c FROM Purchase_Order_Line__c
            WHERE Purchase_Order__c IN :cancelling AND Quantity_Received__c > 0
        ]) {
            receivedOrders.add(line.Purchase_Order__c);
        }
        for (Purchase_Order__c po : newList) {
            if (receivedOrders.contains(po.Id)) {
                po.addError('A purchase order with received goods cannot be cancelled.');
            }
        }
    }

    // The commercial terms agreed with the supplier are frozen once the supplier has confirmed the order.
    private static String changedFieldAfterDispatch(Purchase_Order__c po, Purchase_Order__c old) {
        if (String.isBlank(old.External_Order_Id__c)) return null;
        if (po.External_Order_Id__c != old.External_Order_Id__c) return 'The external order ID';
        if (po.Supplier__c != old.Supplier__c) return 'The supplier';
        if (po.Warehouse__c != old.Warehouse__c) return 'The warehouse';
        if (po.Order_Date__c != old.Order_Date__c) return 'The order date';
        if (po.Subtotal__c != old.Subtotal__c) return 'The subtotal';
        if (po.Tax_Amount__c != old.Tax_Amount__c) return 'The tax amount';
        if (po.Shipping_Amount__c != old.Shipping_Amount__c) return 'The shipping amount';
        return null;
    }

    // ---------------------------------------------------------------- LWC / Aura entry points

    @AuraEnabled(cacheable=true)
    public static PurchaseOrderWrapper getPurchaseOrderWithLines(Id poId) {
        try {
            Purchase_Order__c po = [
                SELECT Id, Name, Status__c, Purchase_Requisition__c, Supplier__c, Supplier__r.Name,
                       Warehouse__c, Warehouse__r.Name, Order_Date__c, Expected_Delivery__c,
                       Supplier_Order_Reference__c, Subtotal__c, Tax_Amount__c, Shipping_Amount__c,
                       Total_Amount__c, Sent_At__c, Last_Sync_Status__c, External_Order_Id__c, Idempotency_Key__c
                FROM Purchase_Order__c WHERE Id = :poId LIMIT 1
            ];
            List<Purchase_Order_Line__c> lines = [
                SELECT Id, Name, Product__c, Product__r.Name, Supplier_Product__c, Supplier_Product__r.Name,
                       Quantity_Ordered__c, Quantity_Received__c, Quantity_Rejected__c,
                       Unit_Price__c, Line_Total__c, Expected_Delivery__c, Line_Status__c
                FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :poId ORDER BY Name
            ];
            PurchaseOrderWrapper w = new PurchaseOrderWrapper();
            w.order = po;
            w.lines = lines;
            w.isEditable = EDITABLE_STATUSES.contains(po.Status__c);
            w.canDispatch = po.Status__c == 'Approved' && po.Last_Sync_Status__c != 'Pending' && String.isBlank(po.External_Order_Id__c);
            return w;
        } catch (Exception e) {
            throw auraError('Error loading purchase order: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Id savePurchaseOrder(String poJson, String linesJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            Purchase_Order__c po = (Purchase_Order__c) JSON.deserialize(poJson, Purchase_Order__c.class);
            List<Purchase_Order_Line__c> lines = (List<Purchase_Order_Line__c>) JSON.deserialize(linesJson, List<Purchase_Order_Line__c>.class);

            if (po.Id == null) {
                if (String.isBlank(po.Status__c)) po.Status__c = 'Draft';
                if (po.Order_Date__c == null) po.Order_Date__c = Date.today();
                insert po;
            } else {
                Purchase_Order__c existing = [SELECT Status__c FROM Purchase_Order__c WHERE Id = :po.Id LIMIT 1];
                if (!EDITABLE_STATUSES.contains(existing.Status__c)) {
                    throw auraError('Cannot edit a purchase order with status: ' + existing.Status__c);
                }
                update po;
            }

            Set<Id> incomingIds = new Set<Id>();
            for (Purchase_Order_Line__c l : lines) { if (l.Id != null) incomingIds.add(l.Id); }
            List<Purchase_Order_Line__c> existingLines = [SELECT Id FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :po.Id];
            List<Purchase_Order_Line__c> toDelete = new List<Purchase_Order_Line__c>();
            for (Purchase_Order_Line__c el : existingLines) {
                if (!incomingIds.contains(el.Id)) toDelete.add(el);
            }
            if (!toDelete.isEmpty()) delete toDelete;

            List<Purchase_Order_Line__c> toInsert = new List<Purchase_Order_Line__c>();
            List<Purchase_Order_Line__c> toUpdate = new List<Purchase_Order_Line__c>();
            for (Purchase_Order_Line__c line : lines) {
                if (line.Id == null) {
                    line.Purchase_Order__c = po.Id;
                    if (line.Line_Status__c == null) line.Line_Status__c = 'Open';
                    toInsert.add(line);
                } else {
                    toUpdate.add(line);
                }
            }
            if (!toInsert.isEmpty()) insert toInsert;
            if (!toUpdate.isEmpty()) update toUpdate;

            return po.Id;
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw auraError('Error saving purchase order: ' + e.getMessage());
        }
    }

    // Converts one approved requisition into purchase orders for a single supplier chosen by the caller.
    // For automatic supplier selection per line use generatePurchaseOrders.
    @AuraEnabled
    public static Id createPurchaseOrderFromRequisition(Id requisitionId, Id supplierId, Id warehouseId) {
        Savepoint sp = Database.setSavepoint();
        try {
            Purchase_Requisition__c req = [
                SELECT Id, Status__c, Destination_Warehouse__c, Estimated_Total__c
                FROM Purchase_Requisition__c WHERE Id = :requisitionId LIMIT 1
            ];
            if (req.Status__c != 'Approved') {
                throw auraError('Only approved requisitions can be converted to purchase orders.');
            }
            List<Requisition_Line__c> reqLines = [
                SELECT Id, Product__c, Requested_Qty__c, Approved_Qty__c, Estimated_Unit_Price__c,
                       Approved_Unit_Price__c, Preferred_Supplier_Product__c
                FROM Requisition_Line__c WHERE Requisition__c = :requisitionId
            ];
            Purchase_Order__c po = new Purchase_Order__c(
                Purchase_Requisition__c = requisitionId,
                Supplier__c = supplierId,
                Warehouse__c = warehouseId != null ? warehouseId : req.Destination_Warehouse__c,
                Order_Date__c = Date.today(),
                Status__c = 'Draft'
            );
            insert po;

            List<Purchase_Order_Line__c> polLines = new List<Purchase_Order_Line__c>();
            for (Requisition_Line__c rl : reqLines) {
                Decimal qty = rl.Approved_Qty__c != null && rl.Approved_Qty__c > 0 ? rl.Approved_Qty__c : rl.Requested_Qty__c;
                Decimal price = rl.Approved_Unit_Price__c != null && rl.Approved_Unit_Price__c > 0 ? rl.Approved_Unit_Price__c : rl.Estimated_Unit_Price__c;
                polLines.add(new Purchase_Order_Line__c(
                    Purchase_Order__c = po.Id,
                    Product__c = rl.Product__c,
                    Supplier_Product__c = rl.Preferred_Supplier_Product__c,
                    Quantity_Ordered__c = qty,
                    Unit_Price__c = price,
                    Line_Status__c = 'Open'
                ));
            }
            if (!polLines.isEmpty()) insert polLines;

            return po.Id;
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw auraError('Error creating PO from requisition: ' + e.getMessage());
        }
    }

    // Requests a supplier dispatch. The order stays Approved and is marked Sent only after the supplier
    // confirms it (see ProcurementDispatchQueueable).
    @AuraEnabled
    public static void dispatchPurchaseOrder(Id poId) {
        Map<Id, String> errors = requestDispatch(new Set<Id>{ poId });
        if (errors.containsKey(poId)) {
            throw auraError(errors.get(poId));
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Purchase_Order__c> getRecentPurchaseOrders(Integer limitCount) {
        try {
            Integer lim = (limitCount != null && limitCount > 0) ? limitCount : 20;
            return [SELECT Id, Name, Status__c, Supplier__r.Name, Warehouse__r.Name,
                           Order_Date__c, Expected_Delivery__c, Total_Amount__c
                    FROM Purchase_Order__c ORDER BY CreatedDate DESC LIMIT :lim];
        } catch (Exception e) {
            throw auraError('Error loading purchase orders: ' + e.getMessage());
        }
    }

    // AuraHandledException hides its message from callers unless setMessage is used.
    private static AuraHandledException auraError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
