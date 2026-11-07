@IsTest
private class SupplierPerformanceServiceTest {

    @TestSetup
    static void setupData() {
        insert new List<Account>{
            new Account(Name = 'Stale Supplier'),
            new Account(Name = 'Risky Supplier'),
            new Account(Name = 'Healthy Supplier'),
            new Account(Name = 'Low Score Supplier')
        };
    }

    private static Id accountId(String name) {
        return [SELECT Id FROM Account WHERE Name = :name LIMIT 1].Id;
    }

    private static Supplier_Scorecard__c card(String supplier, Date periodEnd, Decimal score, String risk) {
        return new Supplier_Scorecard__c(
            Supplier__c = accountId(supplier), Period_End__c = periodEnd, Overall_Score__c = score, Risk_Level__c = risk
        );
    }

    private static SupplierPerformanceService.ReviewResult find(Boolean withDedupe) {
        SupplierPerformanceService.ReviewRequest req = new SupplierPerformanceService.ReviewRequest();
        req.reviewIntervalDays = 90;
        req.minimumScore = 60;
        if (withDedupe) {
            req.taskSubjectPrefix = 'Supplier review due';
            req.dedupeDays = 30;
        }
        return SupplierPerformanceService.findSuppliersDueForReview(new List<SupplierPerformanceService.ReviewRequest>{ req })[0];
    }

    private static Set<Id> dueSuppliers(SupplierPerformanceService.ReviewResult result) {
        Set<Id> ids = new Set<Id>();
        for (Supplier_Scorecard__c c : result.dueScorecards) ids.add(c.Supplier__c);
        return ids;
    }

    @IsTest
    static void testDueRulesStaleHighRiskAndLowScore() {
        insert new List<Supplier_Scorecard__c>{
            card('Stale Supplier', Date.today().addDays(-120), 90, 'Low'),
            card('Risky Supplier', Date.today().addDays(-5), 80, 'High'),
            card('Healthy Supplier', Date.today().addDays(-5), 85, 'Low'),
            card('Low Score Supplier', Date.today().addDays(-5), 40, 'Medium')
        };
        SupplierPerformanceService.ReviewResult result = find(false);
        Set<Id> due = dueSuppliers(result);
        System.assertEquals(3, result.dueCount);
        System.assert(due.contains(accountId('Stale Supplier')));
        System.assert(due.contains(accountId('Risky Supplier')));
        System.assert(due.contains(accountId('Low Score Supplier')));
        System.assert(!due.contains(accountId('Healthy Supplier')));
    }

    @IsTest
    static void testOnlyLatestScorecardPerSupplierIsEvaluated() {
        insert new List<Supplier_Scorecard__c>{
            card('Stale Supplier', Date.today().addDays(-300), 20, 'High'),
            card('Stale Supplier', Date.today().addDays(-10), 90, 'Low')
        };
        System.assertEquals(0, find(false).dueCount, 'The recent, healthy scorecard supersedes the old one');
    }

    @IsTest
    static void testSuppliersWithOpenOrRecentReviewTaskAreSkipped() {
        insert card('Risky Supplier', Date.today().addDays(-5), 80, 'High');
        Supplier_Scorecard__c existing = [SELECT Id FROM Supplier_Scorecard__c LIMIT 1];
        System.assertEquals(1, find(true).dueCount);

        insert new Task(Subject = 'Supplier review due: Risky Supplier', WhatId = existing.Id, Status = 'Completed');
        System.assertEquals(0, find(true).dueCount, 'A review task created inside the dedupe window suppresses a new one');
    }

    @IsTest
    static void testRiskLevelWithNoScorecardsReturnsNothing() {
        System.assertEquals(0, find(true).dueCount);
    }

    @IsTest
    static void testSupplierReviewFlowCreatesOneTaskPerDueSupplierWithoutDuplicates() {
        insert new List<Supplier_Scorecard__c>{
            card('Risky Supplier', Date.today().addDays(-5), 80, 'High'),
            card('Healthy Supplier', Date.today().addDays(-5), 85, 'Low')
        };
        Flow.Interview.createInterview('Supplier_Review_Request', new Map<String, Object>()).start();
        List<Task> tasks = [SELECT Subject, WhatId FROM Task WHERE Subject LIKE 'Supplier review due%'];
        System.assertEquals(1, tasks.size());

        Flow.Interview.createInterview('Supplier_Review_Request', new Map<String, Object>()).start();
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Supplier review due%'], 'A second run must not duplicate the task');
    }

    @IsTest
    static void testRankingsAndScorecardQueries() {
        Supplier_Scorecard__c sc = card('Healthy Supplier', Date.today(), 85, 'Low');
        insert sc;
        System.assertEquals(1, SupplierPerformanceService.getSupplierScorecards(sc.Supplier__c).size());
        System.assertEquals(1, SupplierPerformanceService.getAllSupplierRankings(10).size());
    }
}
