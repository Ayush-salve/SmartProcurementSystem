trigger RequisitionTrigger on Purchase_Requisition__c (before update) {
    RequisitionTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
}
