@IsTest
private class ProcurementNotifyFlowTest {

    private static Flow.Interview run(Map<String, Object> inputs) {
        Flow.Interview flow = Flow.Interview.createInterview('Procurement_Subflow_Notify', inputs);
        flow.start();
        return flow;
    }

    private static Warehouse__c warehouse() {
        Warehouse__c wh = new Warehouse__c(Name = 'Notify WH', Warehouse_Code__c = 'NWH', Active__c = true);
        insert wh;
        return wh;
    }

    @IsTest
    static void testCreatesFollowUpTaskWhenRequested() {
        Warehouse__c wh = warehouse();
        Flow.Interview flow = run(new Map<String, Object>{
            'recordId' => String.valueOf(wh.Id),
            'recipientId' => String.valueOf(UserInfo.getUserId()),
            'title' => 'Follow up',
            'message' => 'Please follow up.',
            'createTask' => true,
            'taskDueInDays' => 3
        });
        System.assertEquals(true, flow.getVariableValue('taskCreated'));
        Task t = [SELECT Subject, OwnerId, WhatId, ActivityDate, Status FROM Task WHERE WhatId = :wh.Id];
        System.assertEquals('Follow up', t.Subject);
        System.assertEquals(UserInfo.getUserId(), t.OwnerId);
        System.assertEquals(Date.today().addDays(3), t.ActivityDate);
        System.assertEquals('Not Started', t.Status);
    }

    @IsTest
    static void testNoTaskUnlessRequested() {
        Warehouse__c wh = warehouse();
        run(new Map<String, Object>{
            'recordId' => String.valueOf(wh.Id),
            'recipientId' => String.valueOf(UserInfo.getUserId()),
            'title' => 'FYI',
            'message' => 'No task needed.'
        });
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :wh.Id]);
    }

    @IsTest
    static void testDuplicateAlertsAreSuppressedWithinWindow() {
        Warehouse__c wh = warehouse();
        Map<String, Object> inputs = new Map<String, Object>{
            'recordId' => String.valueOf(wh.Id),
            'recipientId' => String.valueOf(UserInfo.getUserId()),
            'title' => 'Repeated alert',
            'message' => 'Same alert.',
            'createTask' => true,
            'dedupeDays' => 7
        };
        run(inputs);
        Flow.Interview second = run(inputs);
        System.assertEquals(true, second.getVariableValue('skippedAsDuplicate'));
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :wh.Id]);
    }

    @IsTest
    static void testMissingRecipientOrTitleIsReported() {
        Flow.Interview flow = run(new Map<String, Object>{ 'title' => 'No recipient' });
        System.assertNotEquals(null, flow.getVariableValue('errorMessage'));
        System.assertNotEquals(true, flow.getVariableValue('notificationSent'));
        System.assertNotEquals(true, flow.getVariableValue('taskCreated'));
    }
}
