public with sharing class SupplierPerformanceService {

    public class SupplierRankingWrapper {
        @AuraEnabled public Id supplierId;
        @AuraEnabled public String supplierName;
        @AuraEnabled public Decimal overallScore;
        @AuraEnabled public Decimal onTimeRate;
        @AuraEnabled public Decimal defectRate;
        @AuraEnabled public Decimal avgLeadTime;
        @AuraEnabled public String riskLevel;
        @AuraEnabled public Integer ordersEvaluated;
        @AuraEnabled public Date latestPeriodEnd;
    }

    @AuraEnabled(cacheable=true)
    public static List<Supplier_Scorecard__c> getSupplierScorecards(Id supplierId) {
        try {
            return [SELECT Id, Name, Supplier__c, Supplier__r.Name, Period_Start__c, Period_End__c,
                           Orders_Evaluated__c, On_Time_Rate__c, Defect_Rate__c, Average_Lead_Time__c,
                           Price_Score__c, Reliability_Score__c, Overall_Score__c, Risk_Level__c,
                           Calculation_Version__c, Calculated_At__c
                    FROM Supplier_Scorecard__c
                    WHERE Supplier__c = :supplierId
                    ORDER BY Period_End__c DESC LIMIT 24];
        } catch (Exception e) {
            throw new AuraHandledException('Error loading supplier scorecards: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<SupplierRankingWrapper> getAllSupplierRankings(Integer limitCount) {
        try {
            Integer lim = (limitCount != null && limitCount > 0) ? limitCount : 20;
            // Get most recent scorecard per supplier using aggregate
            List<AggregateResult> latestDates = [
                SELECT Supplier__c, MAX(Period_End__c) latestDate
                FROM Supplier_Scorecard__c
                GROUP BY Supplier__c
                LIMIT :lim
            ];
            Set<Id> supplierIds = new Set<Id>();
            Map<Id, Date> latestBySupplier = new Map<Id, Date>();
            for (AggregateResult ar : latestDates) {
                Id sid = (Id) ar.get('Supplier__c');
                supplierIds.add(sid);
                latestBySupplier.put(sid, (Date) ar.get('latestDate'));
            }

            List<Supplier_Scorecard__c> cards = [
                SELECT Id, Supplier__c, Supplier__r.Name, Period_End__c,
                       Overall_Score__c, On_Time_Rate__c, Defect_Rate__c, Average_Lead_Time__c,
                       Risk_Level__c, Orders_Evaluated__c
                FROM Supplier_Scorecard__c
                WHERE Supplier__c IN :supplierIds
                ORDER BY Overall_Score__c DESC NULLS LAST
            ];

            Map<Id, Supplier_Scorecard__c> latestCard = new Map<Id, Supplier_Scorecard__c>();
            for (Supplier_Scorecard__c sc : cards) {
                if (!latestCard.containsKey(sc.Supplier__c) ||
                    (sc.Period_End__c != null && sc.Period_End__c >= latestBySupplier.get(sc.Supplier__c))) {
                    latestCard.put(sc.Supplier__c, sc);
                }
            }

            List<SupplierRankingWrapper> result = new List<SupplierRankingWrapper>();
            for (Supplier_Scorecard__c sc : latestCard.values()) {
                SupplierRankingWrapper w = new SupplierRankingWrapper();
                w.supplierId = sc.Supplier__c;
                w.supplierName = sc.Supplier__r != null ? sc.Supplier__r.Name : '';
                w.overallScore = sc.Overall_Score__c;
                w.onTimeRate = sc.On_Time_Rate__c;
                w.defectRate = sc.Defect_Rate__c;
                w.avgLeadTime = sc.Average_Lead_Time__c;
                w.riskLevel = sc.Risk_Level__c;
                w.ordersEvaluated = sc.Orders_Evaluated__c != null ? Integer.valueOf(sc.Orders_Evaluated__c) : 0;
                w.latestPeriodEnd = sc.Period_End__c;
                result.add(w);
            }
            result.sort();
            return result;
        } catch (Exception e) {
            throw new AuraHandledException('Error loading supplier rankings: ' + e.getMessage());
        }
    }
}
