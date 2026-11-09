public with sharing class InventoryTriggerHandler {

    public static void beforeInsert(List<Inventory__c> newList) {
        InventoryService.validateAndDeriveStockFields(newList, null);
    }

    public static void beforeUpdate(List<Inventory__c> newList, Map<Id, Inventory__c> oldMap) {
        InventoryService.validateAndDeriveStockFields(newList, oldMap);
    }
}
