public with sharing class GoodsReceiptLineTriggerHandler {

    public static void beforeSave(List<Goods_Receipt_Line__c> newList) {
        GoodsReceiptService.validateReceiptLines(newList);
    }
}
