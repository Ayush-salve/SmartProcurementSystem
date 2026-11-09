public with sharing class GoodsReceiptTriggerHandler {

    public static void beforeUpdate(List<Goods_Receipt__c> newList, Map<Id, Goods_Receipt__c> oldMap) {
        GoodsReceiptService.enforcePostingRules(newList, oldMap);
    }
}
