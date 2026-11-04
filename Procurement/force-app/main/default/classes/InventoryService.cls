public with sharing class InventoryService {

    public class InventoryWrapper {
        @AuraEnabled public Id inventoryId;
        @AuraEnabled public String inventoryName;
        @AuraEnabled public String productName;
        @AuraEnabled public Id productId;
        @AuraEnabled public String warehouseName;
        @AuraEnabled public Id warehouseId;
        @AuraEnabled public Decimal onHand;
        @AuraEnabled public Decimal reserved;
        @AuraEnabled public Decimal onOrder;
        @AuraEnabled public Decimal available;
        @AuraEnabled public Decimal safetyStock;
        @AuraEnabled public Decimal reorderPoint;
        @AuraEnabled public String reorderStatus;
        @AuraEnabled public Decimal leadTimeDays;
        @AuraEnabled public Decimal avgDailyDemand;
        @AuraEnabled public Date lastStockCheck;
        @AuraEnabled public Boolean isLowStock;
    }

    @AuraEnabled(cacheable=true)
    public static List<InventoryWrapper> getInventoryRecords(String searchTerm, String reorderStatusFilter) {
        try {
            String query = 'SELECT Id, Name, Product__c, Product__r.Name, Warehouse__c, Warehouse__r.Name, ' +
                           'On_Hand__c, Reserved__c, On_Order__c, Available_Stock__c, Safety_Stock__c, ' +
                           'Reorder_Point__c, Reorder_Status__c, Lead_Time_Days__c, Average_Daily_Demand__c, ' +
                           'Last_Stock_Check__c ' +
                           'FROM Inventory__c';
            List<String> conditions = new List<String>();
            if (String.isNotBlank(searchTerm)) {
                conditions.add('Product__r.Name LIKE \'%' + String.escapeSingleQuotes(searchTerm) + '%\'');
            }
            if (String.isNotBlank(reorderStatusFilter) && reorderStatusFilter != 'All') {
                conditions.add('Reorder_Status__c = \'' + String.escapeSingleQuotes(reorderStatusFilter) + '\'');
            }
            if (!conditions.isEmpty()) {
                query += ' WHERE ' + String.join(conditions, ' AND ');
            }
            query += ' ORDER BY Reorder_Status__c, Product__r.Name LIMIT 200';
            List<Inventory__c> records = Database.query(query);
            List<InventoryWrapper> result = new List<InventoryWrapper>();
            for (Inventory__c inv : records) {
                InventoryWrapper w = new InventoryWrapper();
                w.inventoryId = inv.Id;
                w.inventoryName = inv.Name;
                w.productId = inv.Product__c;
                w.productName = inv.Product__r != null ? inv.Product__r.Name : '';
                w.warehouseId = inv.Warehouse__c;
                w.warehouseName = inv.Warehouse__r != null ? inv.Warehouse__r.Name : '';
                w.onHand = inv.On_Hand__c != null ? inv.On_Hand__c : 0;
                w.reserved = inv.Reserved__c != null ? inv.Reserved__c : 0;
                w.onOrder = inv.On_Order__c != null ? inv.On_Order__c : 0;
                w.available = inv.Available_Stock__c != null ? inv.Available_Stock__c : 0;
                w.safetyStock = inv.Safety_Stock__c != null ? inv.Safety_Stock__c : 0;
                w.reorderPoint = inv.Reorder_Point__c != null ? inv.Reorder_Point__c : 0;
                w.reorderStatus = inv.Reorder_Status__c;
                w.leadTimeDays = inv.Lead_Time_Days__c;
                w.avgDailyDemand = inv.Average_Daily_Demand__c;
                w.lastStockCheck = inv.Last_Stock_Check__c;
                w.isLowStock = (w.available <= w.reorderPoint);
                result.add(w);
            }
            return result;
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching inventory: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static Inventory__c getInventoryById(Id inventoryId) {
        try {
            return [SELECT Id, Name, Product__c, Product__r.Name, Warehouse__c, Warehouse__r.Name,
                           On_Hand__c, Reserved__c, On_Order__c, Available_Stock__c, Safety_Stock__c,
                           Reorder_Point__c, Reorder_Status__c, Lead_Time_Days__c, Average_Daily_Demand__c,
                           Last_Stock_Check__c, Last_Reorder_Run__c
                    FROM Inventory__c WHERE Id = :inventoryId LIMIT 1];
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching inventory record: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Boolean updateReorderStatus(Id inventoryId, String newStatus) {
        try {
            Inventory__c inv = new Inventory__c(
                Id = inventoryId,
                Reorder_Status__c = newStatus,
                Last_Reorder_Run__c = Datetime.now()
            );
            update inv;
            return true;
        } catch (Exception e) {
            throw new AuraHandledException('Error updating reorder status: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Integer evaluateAndUpdateReorderStatuses() {
        try {
            List<Inventory__c> all = [
                SELECT Id, Available_Stock__c, Reorder_Point__c, Reorder_Status__c
                FROM Inventory__c
            ];
            List<Inventory__c> toUpdate = new List<Inventory__c>();
            for (Inventory__c inv : all) {
                Decimal available = inv.Available_Stock__c != null ? inv.Available_Stock__c : 0;
                Decimal reorderPt = inv.Reorder_Point__c != null ? inv.Reorder_Point__c : 0;
                String newStatus;
                if (available <= 0 || available <= reorderPt) {
                    newStatus = 'Reorder Needed';
                } else if (reorderPt > 0 && available <= reorderPt * 1.5) {
                    newStatus = 'At Risk';
                } else {
                    newStatus = 'Healthy';
                }
                if (newStatus != inv.Reorder_Status__c) {
                    toUpdate.add(new Inventory__c(Id = inv.Id, Reorder_Status__c = newStatus, Last_Reorder_Run__c = Datetime.now()));
                }
            }
            if (!toUpdate.isEmpty()) update toUpdate;
            return toUpdate.size();
        } catch (Exception e) {
            throw new AuraHandledException('Error evaluating reorder statuses: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Warehouse__c> getActiveWarehouses() {
        try {
            return [SELECT Id, Name, Warehouse_Code__c, Location__c FROM Warehouse__c WHERE Active__c = true ORDER BY Name LIMIT 100];
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching warehouses: ' + e.getMessage());
        }
    }
}
