public with sharing class InventoryService {

    private static final Decimal AT_RISK_FACTOR = 1.2;

    // Single source of truth for reorder classification (used by LWC, batch evaluation and the flow).
    public static String classifyReorderStatus(Decimal onHand, Decimal reserved, Decimal reorderPoint) {
        Decimal available = (onHand == null ? 0 : onHand) - (reserved == null ? 0 : reserved);
        Decimal reorderPt = reorderPoint == null ? 0 : reorderPoint;
        if (available <= reorderPt) {
            return 'Reorder Needed';
        }
        if (reorderPt > 0 && available <= reorderPt * AT_RISK_FACTOR) {
            return 'At Risk';
        }
        return 'Healthy';
    }

    public class ReorderEvaluationRequest {
        @InvocableVariable(label='Inventory Id' required=true)
        public Id inventoryId;
    }

    public class ReorderEvaluationResult {
        @InvocableVariable(label='Inventory Id')
        public Id inventoryId;
        @InvocableVariable(label='Reorder Status')
        public String reorderStatus;
        @InvocableVariable(label='Status Changed')
        public Boolean statusChanged;
        @InvocableVariable(label='Newly Reorder Needed')
        public Boolean newlyReorderNeeded;
        @InvocableVariable(label='Notify User Id')
        public String notifyUserId;
        @InvocableVariable(label='Message')
        public String message;
    }

    // Only Reorder_Status__c and Last_Reorder_Run__c are written, and only when the status changes,
    // so the calling record-triggered flow (which listens to stock fields) is not re-entered.
    @InvocableMethod(
        label='Evaluate Inventory Reorder Status'
        description='Authoritative reorder classification. Updates Reorder_Status__c when it changed and reports whether a reorder alert is needed.'
    )
    public static List<ReorderEvaluationResult> evaluateReorderFromFlow(List<ReorderEvaluationRequest> requests) {
        Set<Id> ids = new Set<Id>();
        for (ReorderEvaluationRequest r : requests) {
            if (r.inventoryId != null) ids.add(r.inventoryId);
        }
        Map<Id, Inventory__c> records = new Map<Id, Inventory__c>([
            SELECT Id, On_Hand__c, Reserved__c, Reorder_Point__c, Reorder_Status__c, Warehouse__r.Manager__c
            FROM Inventory__c WHERE Id IN :ids WITH USER_MODE
        ]);

        List<Inventory__c> toUpdate = new List<Inventory__c>();
        Map<Id, ReorderEvaluationResult> resultById = new Map<Id, ReorderEvaluationResult>();
        for (Inventory__c inv : records.values()) {
            String newStatus = classifyReorderStatus(inv.On_Hand__c, inv.Reserved__c, inv.Reorder_Point__c);
            ReorderEvaluationResult res = new ReorderEvaluationResult();
            res.inventoryId = inv.Id;
            res.reorderStatus = newStatus;
            res.statusChanged = newStatus != inv.Reorder_Status__c;
            res.newlyReorderNeeded = res.statusChanged && newStatus == 'Reorder Needed';
            if (res.newlyReorderNeeded && inv.Warehouse__r != null && inv.Warehouse__r.Manager__c != null) {
                res.notifyUserId = String.valueOf(inv.Warehouse__r.Manager__c);
            }
            res.message = 'Reorder status is ' + newStatus + '.';
            resultById.put(inv.Id, res);
            if (res.statusChanged) {
                toUpdate.add(new Inventory__c(Id = inv.Id, Reorder_Status__c = newStatus, Last_Reorder_Run__c = Datetime.now()));
            }
        }

        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] saveResults = Database.update(toUpdate, false);
            for (Integer i = 0; i < saveResults.size(); i++) {
                if (!saveResults[i].isSuccess()) {
                    ReorderEvaluationResult res = resultById.get(toUpdate[i].Id);
                    res.statusChanged = false;
                    res.newlyReorderNeeded = false;
                    res.notifyUserId = null;
                    res.message = 'Reorder status update failed: ' + saveResults[i].getErrors()[0].getMessage();
                }
            }
        }

        List<ReorderEvaluationResult> output = new List<ReorderEvaluationResult>();
        for (ReorderEvaluationRequest r : requests) {
            ReorderEvaluationResult res = resultById.get(r.inventoryId);
            if (res == null) {
                res = new ReorderEvaluationResult();
                res.inventoryId = r.inventoryId;
                res.statusChanged = false;
                res.newlyReorderNeeded = false;
                res.message = 'Inventory record not found or not accessible.';
            }
            output.add(res);
        }
        return output;
    }

    public class InventoryWrapper {
        @AuraEnabled public Id inventoryId { get; set; }
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public Id warehouseId { get; set; }
        @AuraEnabled public String warehouseName { get; set; }
        @AuraEnabled public Decimal onHand { get; set; }
        @AuraEnabled public Decimal reserved { get; set; }
        @AuraEnabled public Decimal available { get; set; }
        @AuraEnabled public Decimal reorderPoint { get; set; }
        @AuraEnabled public String reorderStatus { get; set; }
        @AuraEnabled public Date lastStockCheck { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<InventoryWrapper> getInventoryRecords(
        String searchTerm,
        String reorderStatusFilter
    ) {
        List<InventoryWrapper> results = new List<InventoryWrapper>();

        List<Inventory__c> records = [
            SELECT Id,
                   Product__c, Product__r.Name,
                   Warehouse__c, Warehouse__r.Name,
                   On_Hand__c, Reserved__c,
                   Reorder_Point__c, Last_Stock_Check__c
            FROM Inventory__c
            WHERE Product__c != null
            WITH USER_MODE
            ORDER BY Last_Stock_Check__c DESC NULLS LAST
            LIMIT 2000
        ];

        for (Inventory__c item : records) {
            Decimal onHand      = item.On_Hand__c == null      ? 0 : item.On_Hand__c;
            Decimal reserved    = item.Reserved__c == null     ? 0 : item.Reserved__c;
            Decimal reorderPt   = item.Reorder_Point__c == null ? 0 : item.Reorder_Point__c;
            Decimal available   = onHand - reserved;

            String status = classifyReorderStatus(onHand, reserved, reorderPt);

            if (reorderStatusFilter != null &&
                reorderStatusFilter != 'All' &&
                reorderStatusFilter != status) {
                continue;
            }

            if (String.isNotBlank(searchTerm)) {
                String productName   = item.Product__r.Name;
                String warehouseName = item.Warehouse__r == null ? '' : item.Warehouse__r.Name;
                if (!productName.containsIgnoreCase(searchTerm) &&
                    !warehouseName.containsIgnoreCase(searchTerm)) {
                    continue;
                }
            }

            InventoryWrapper wrapper    = new InventoryWrapper();
            wrapper.inventoryId         = item.Id;
            wrapper.productId           = item.Product__c;
            wrapper.productName         = item.Product__r.Name;
            wrapper.warehouseId         = item.Warehouse__c;
            wrapper.warehouseName       = item.Warehouse__r == null ? '' : item.Warehouse__r.Name;
            wrapper.onHand              = onHand;
            wrapper.reserved            = reserved;
            wrapper.available           = available;
            wrapper.reorderPoint        = reorderPt;
            wrapper.reorderStatus       = status;
            wrapper.lastStockCheck      = item.Last_Stock_Check__c;
            results.add(wrapper);
        }

        return results;
    }

    @AuraEnabled(cacheable=true)
    public static List<Warehouse__c> getActiveWarehouses() {
        return [
            SELECT Id, Name
            FROM Warehouse__c
            WHERE Active__c = true
            WITH USER_MODE
            ORDER BY Name
        ];
    }

    @AuraEnabled
    public static Integer evaluateAndUpdateReorderStatuses() {
        List<Inventory__c> records = [
            SELECT Id, On_Hand__c, Reserved__c, Reorder_Point__c
            FROM Inventory__c
            LIMIT 2000
        ];

        List<Inventory__c> toUpdate = new List<Inventory__c>();
        for (Inventory__c inv : records) {
            String newStatus = classifyReorderStatus(inv.On_Hand__c, inv.Reserved__c, inv.Reorder_Point__c);

            toUpdate.add(new Inventory__c(
                Id = inv.Id,
                Reorder_Status__c = newStatus,
                Last_Reorder_Run__c = Datetime.now()
            ));
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }

        return toUpdate.size();
    }

    @AuraEnabled
    public static Boolean updateReorderStatus(Id inventoryId, String status) {
        try {
            update new Inventory__c(Id = inventoryId, Reorder_Status__c = status);
            return true;
        } catch (Exception e) {
            throw auraError('Error updating reorder status: ' + e.getMessage());
        }
    }

    // AuraHandledException hides its message from callers unless setMessage is used.
    private static AuraHandledException auraError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
