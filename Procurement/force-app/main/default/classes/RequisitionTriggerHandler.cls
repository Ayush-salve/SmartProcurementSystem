public with sharing class RequisitionTriggerHandler {

    public static void beforeUpdate(List<Purchase_Requisition__c> newList, Map<Id, Purchase_Requisition__c> oldMap) {
        List<Purchase_Requisition__c> statusChanged = new List<Purchase_Requisition__c>();
        for (Purchase_Requisition__c req : newList) {
            if (req.Status__c != oldMap.get(req.Id).Status__c) statusChanged.add(req);
        }
        if (!statusChanged.isEmpty()) {
            RequisitionService.enforceTransitionsAndSubmissionRules(statusChanged, oldMap);
        }
    }
}
