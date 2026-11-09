trigger GoodsReceiptLineTrigger on Goods_Receipt_Line__c (before insert, before update) {
    GoodsReceiptLineTriggerHandler.beforeSave(Trigger.new);
}
