trigger GoodsReceiptTrigger on Goods_Receipt__c (before update) {
    GoodsReceiptTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
}
