public with sharing class PurchaseOrderTriggerHandler {

    public static void beforeUpdate(List<Purchase_Order__c> newList, Map<Id, Purchase_Order__c> oldMap) {
        PurchaseOrderService.enforceOrderRules(newList, oldMap);
    }
}
