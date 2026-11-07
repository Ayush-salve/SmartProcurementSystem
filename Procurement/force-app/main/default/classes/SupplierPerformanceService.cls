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

    public class ReviewRequest {
        @InvocableVariable(label='Review Interval (days)' description='A supplier is due when its latest scorecard period ended at least this many days ago. Defaults to 90.')
        public Integer reviewIntervalDays;
        @InvocableVariable(label='Minimum Acceptable Score' description='A supplier is due when its latest overall score is below this value. Defaults to 60.')
        public Decimal minimumScore;
        @InvocableVariable(label='Task Subject Prefix' description='Suppliers whose scorecard already has an open or recent task whose subject starts with this prefix are skipped.')
        public String taskSubjectPrefix;
        @InvocableVariable(label='Dedupe Window (days)' description='A review task created within this many days counts as recent. Defaults to 30.')
        public Integer dedupeDays;
    }

    public class ReviewResult {
        @InvocableVariable(label='Due Scorecards' description='The latest scorecard of every supplier that is due for review.')
        public List<Supplier_Scorecard__c> dueScorecards;
        @InvocableVariable(label='Due Count')
        public Integer dueCount;
    }

    // A supplier is due when its latest scorecard is stale, High risk, or scores below the minimum.
    @InvocableMethod(
        label='Find Suppliers Due For Review'
        description='Returns the latest scorecard of each supplier that is stale, High risk, or below the minimum score.'
    )
    public static List<ReviewResult> findSuppliersDueForReview(List<ReviewRequest> requests) {
        List<ReviewResult> results = new List<ReviewResult>();
        for (ReviewRequest request : requests) {
            Integer intervalDays = request.reviewIntervalDays != null && request.reviewIntervalDays > 0 ? request.reviewIntervalDays : 90;
            Decimal minScore = request.minimumScore != null ? request.minimumScore : 60;
            Date staleBefore = Date.today().addDays(-intervalDays);

            Map<Id, Supplier_Scorecard__c> latestBySupplier = new Map<Id, Supplier_Scorecard__c>();
            for (Supplier_Scorecard__c card : [
                SELECT Id, Name, OwnerId, Supplier__c, Supplier__r.Name, Period_End__c,
                       Overall_Score__c, Risk_Level__c, Calculated_At__c
                FROM Supplier_Scorecard__c
                WHERE Supplier__c != null
                WITH USER_MODE
                ORDER BY Supplier__c, Period_End__c DESC NULLS LAST, Calculated_At__c DESC NULLS LAST
                LIMIT 2000
            ]) {
                if (!latestBySupplier.containsKey(card.Supplier__c)) {
                    latestBySupplier.put(card.Supplier__c, card);
                }
            }

            Set<Id> alreadyTasked = findAlreadyTasked(latestBySupplier.values(), request);

            ReviewResult result = new ReviewResult();
            result.dueScorecards = new List<Supplier_Scorecard__c>();
            for (Supplier_Scorecard__c card : latestBySupplier.values()) {
                Boolean stale = card.Period_End__c == null || card.Period_End__c <= staleBefore;
                Boolean highRisk = card.Risk_Level__c == 'High';
                Boolean lowScore = card.Overall_Score__c != null && card.Overall_Score__c < minScore;
                if ((stale || highRisk || lowScore) && !alreadyTasked.contains(card.Id)) {
                    result.dueScorecards.add(card);
                }
            }
            result.dueCount = result.dueScorecards.size();
            results.add(result);
        }
        return results;
    }

    // Scorecards that already have an open task, or one created inside the dedupe window, with the review subject prefix.
    private static Set<Id> findAlreadyTasked(List<Supplier_Scorecard__c> cards, ReviewRequest request) {
        Set<Id> tasked = new Set<Id>();
        if (String.isBlank(request.taskSubjectPrefix) || cards.isEmpty()) {
            return tasked;
        }
        Integer windowDays = request.dedupeDays != null && request.dedupeDays > 0 ? request.dedupeDays : 30;
        Datetime cutoff = Datetime.now().addDays(-windowDays);
        String pattern = String.escapeSingleQuotes(request.taskSubjectPrefix) + '%';
        Set<Id> cardIds = new Map<Id, Supplier_Scorecard__c>(cards).keySet();
        for (Task t : [
            SELECT WhatId FROM Task
            WHERE WhatId IN :cardIds AND Subject LIKE :pattern AND (IsClosed = false OR CreatedDate >= :cutoff)
            WITH USER_MODE
        ]) {
            tasked.add(t.WhatId);
        }
        return tasked;
    }

    @AuraEnabled(cacheable=true)
    public static List<Supplier_Scorecard__c> getSupplierScorecards(Id supplierId) {
        try {
            return [
                SELECT Id, Name, Supplier__c, Supplier__r.Name,
                       Period_Start__c, Period_End__c,
                       Orders_Evaluated__c, On_Time_Rate__c, Defect_Rate__c,
                       Average_Lead_Time__c, Price_Score__c, Reliability_Score__c,
                       Overall_Score__c, Risk_Level__c,
                       Calculation_Version__c, Calculated_At__c
                FROM Supplier_Scorecard__c
                WHERE Supplier__c = :supplierId
                WITH USER_MODE
                ORDER BY Period_End__c DESC
                LIMIT 24
            ];
        } catch (Exception e) {
            throw auraError('Error loading supplier scorecards: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<SupplierRankingWrapper> getAllSupplierRankings(Integer limitCount) {
        try {
            Integer lim = (limitCount != null && limitCount > 0) ? limitCount : 20;

            List<AggregateResult> latestDates = [
                SELECT Supplier__c, MAX(Period_End__c) latestDate
                FROM Supplier_Scorecard__c
                WITH USER_MODE
                GROUP BY Supplier__c
                LIMIT :lim
            ];

            if (latestDates.isEmpty()) {
                return new List<SupplierRankingWrapper>();
            }

            Set<Id> supplierIds = new Set<Id>();
            Map<Id, Date> latestBySupplier = new Map<Id, Date>();
            for (AggregateResult ar : latestDates) {
                Id sid = (Id) ar.get('Supplier__c');
                supplierIds.add(sid);
                latestBySupplier.put(sid, (Date) ar.get('latestDate'));
            }

            List<Supplier_Scorecard__c> cards = [
                SELECT Id, Supplier__c, Supplier__r.Name, Period_End__c,
                       Overall_Score__c, On_Time_Rate__c, Defect_Rate__c,
                       Average_Lead_Time__c, Risk_Level__c, Orders_Evaluated__c
                FROM Supplier_Scorecard__c
                WHERE Supplier__c IN :supplierIds
                WITH USER_MODE
                ORDER BY Overall_Score__c DESC NULLS LAST
                LIMIT 200
            ];

            Map<Id, Supplier_Scorecard__c> latestCard = new Map<Id, Supplier_Scorecard__c>();
            for (Supplier_Scorecard__c sc : cards) {
                Date latestDate = latestBySupplier.get(sc.Supplier__c);
                if (!latestCard.containsKey(sc.Supplier__c) ||
                    (sc.Period_End__c != null && latestDate != null &&
                     sc.Period_End__c >= latestDate)) {
                    latestCard.put(sc.Supplier__c, sc);
                }
            }

            List<SupplierRankingWrapper> result = new List<SupplierRankingWrapper>();
            for (Supplier_Scorecard__c sc : latestCard.values()) {
                SupplierRankingWrapper w = new SupplierRankingWrapper();
                w.supplierId      = sc.Supplier__c;
                w.supplierName    = sc.Supplier__r != null ? sc.Supplier__r.Name : '';
                w.overallScore    = sc.Overall_Score__c;
                w.onTimeRate      = sc.On_Time_Rate__c;
                w.defectRate      = sc.Defect_Rate__c;
                w.avgLeadTime     = sc.Average_Lead_Time__c;
                w.riskLevel       = sc.Risk_Level__c;
                w.ordersEvaluated = sc.Orders_Evaluated__c != null
                                    ? Integer.valueOf(sc.Orders_Evaluated__c) : 0;
                w.latestPeriodEnd = sc.Period_End__c;
                result.add(w);
            }
            return result;

        } catch (Exception e) {
            throw auraError('Error loading supplier rankings: ' + e.getMessage());
        }
    }

    // AuraHandledException hides its message from callers unless setMessage is used.
    private static AuraHandledException auraError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
