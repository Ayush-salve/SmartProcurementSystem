public with sharing class IntegrationMonitorService {

    public class IntegrationStatus {
        @AuraEnabled public Boolean isConfigured;
        @AuraEnabled public String message;
        @AuraEnabled public Integer pendingCount;
        @AuraEnabled public Integer failedCount;
        @AuraEnabled public Integer successCount;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean isIntegrationLogConfigured() {
        // Integration_Log__c object does not exist in current data model.
        // This will be created in a future integration phase.
        return false;
    }

    @AuraEnabled(cacheable=true)
    public static IntegrationStatus getIntegrationStatus() {
        IntegrationStatus status = new IntegrationStatus();
        status.isConfigured = false;
        status.message = 'Integration logging has not been configured yet. Create the Integration_Log__c object in a future integration phase to enable this feature.';
        status.pendingCount = 0;
        status.failedCount = 0;
        status.successCount = 0;
        return status;
    }
}
