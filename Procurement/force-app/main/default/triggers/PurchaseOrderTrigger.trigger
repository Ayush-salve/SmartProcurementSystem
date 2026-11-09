trigger PurchaseOrderTrigger on Purchase_Order__c (before update) {
    PurchaseOrderTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
}
