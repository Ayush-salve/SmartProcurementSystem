public with sharing class ProcurementConfig {

    public class Settings {
        public Decimal priceWeight = 20;
        public Decimal qualityWeight = 40;
        public Decimal deliveryWeight = 40;
        public Decimal leadTimeWeight = 0;
        public Decimal riskHighBelow = 50;
        public Decimal riskMediumBelow = 75;
        public Integer scorecardPeriodDays = 90;
        public Integer maxDispatchAttempts = 3;
        public Integer retryDelayMinutes = 2;
        public String aiNamedCredential;
    }

    @TestVisible private static Settings testOverride;
    private static Settings cached;

    // Reads the Default record of Procurement_Setting__mdt. Missing record or blank fields fall back to the
    // defaults above, so a partially configured org keeps working.
    public static Settings get() {
        if (testOverride != null) return testOverride;
        if (cached != null) return cached;
        Settings s = new Settings();
        Procurement_Setting__mdt record = Procurement_Setting__mdt.getInstance('Default');
        if (record != null) {
            if (record.Price_Weight__c != null) s.priceWeight = record.Price_Weight__c;
            if (record.Quality_Weight__c != null) s.qualityWeight = record.Quality_Weight__c;
            if (record.Delivery_Weight__c != null) s.deliveryWeight = record.Delivery_Weight__c;
            if (record.Lead_Time_Weight__c != null) s.leadTimeWeight = record.Lead_Time_Weight__c;
            if (record.Risk_High_Below__c != null) s.riskHighBelow = record.Risk_High_Below__c;
            if (record.Risk_Medium_Below__c != null) s.riskMediumBelow = record.Risk_Medium_Below__c;
            if (record.Scorecard_Period_Days__c != null && record.Scorecard_Period_Days__c > 0) {
                s.scorecardPeriodDays = Integer.valueOf(record.Scorecard_Period_Days__c);
            }
            if (record.Max_Dispatch_Attempts__c != null && record.Max_Dispatch_Attempts__c > 0) {
                s.maxDispatchAttempts = Integer.valueOf(record.Max_Dispatch_Attempts__c);
            }
            if (record.Retry_Delay_Minutes__c != null && record.Retry_Delay_Minutes__c > 0) {
                s.retryDelayMinutes = Integer.valueOf(record.Retry_Delay_Minutes__c);
            }
            if (String.isNotBlank(record.AI_Named_Credential__c)) s.aiNamedCredential = record.AI_Named_Credential__c.trim();
        }
        if (s.priceWeight + s.qualityWeight + s.deliveryWeight + s.leadTimeWeight <= 0) {
            Settings defaults = new Settings();
            s.priceWeight = defaults.priceWeight;
            s.qualityWeight = defaults.qualityWeight;
            s.deliveryWeight = defaults.deliveryWeight;
            s.leadTimeWeight = defaults.leadTimeWeight;
        }
        cached = s;
        return s;
    }
}
