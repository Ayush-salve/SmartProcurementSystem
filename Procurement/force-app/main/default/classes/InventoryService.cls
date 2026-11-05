public with sharing class InventoryService {

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

            String status;
            if (available <= reorderPt) {
                status = 'Reorder Needed';
            } else if (reorderPt > 0 && available <= reorderPt * 1.2) {
                status = 'At Risk';
            } else {
                status = 'Healthy';
            }

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
            Decimal onHand    = inv.On_Hand__c == null       ? 0 : inv.On_Hand__c;
            Decimal reserved  = inv.Reserved__c == null      ? 0 : inv.Reserved__c;
            Decimal reorderPt = inv.Reorder_Point__c == null ? 0 : inv.Reorder_Point__c;
            Decimal available = onHand - reserved;

            String newStatus;
            if (available <= reorderPt) {
                newStatus = 'Reorder Needed';
            } else if (reorderPt > 0 && available <= reorderPt * 1.2) {
                newStatus = 'At Risk';
            } else {
                newStatus = 'Healthy';
            }

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
            throw new AuraHandledException('Error updating reorder status: ' + e.getMessage());
        }
    }
}
