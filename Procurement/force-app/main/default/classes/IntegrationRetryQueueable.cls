public with sharing class IntegrationRetryQueueable implements Queueable, Database.AllowsCallouts {

    // Queueable delay limit is 10 minutes.
    private static final Integer MAX_DELAY_MINUTES = 10;

    // Test hook: chained queueables cannot run inside a test, so the scheduled retry is recorded instead.
    @TestVisible private static List<RetryRequest> scheduledInTest = new List<RetryRequest>();

    public class RetryRequest {
        public List<Id> orderIds;
        public Integer nextAttempt;
        public Integer delayMinutes;
    }

    private final List<Id> orderIds;
    private final Integer attempt;

    public IntegrationRetryQueueable(List<Id> orderIds, Integer attempt) {
        this.orderIds = orderIds;
        this.attempt = attempt;
    }

    // A retry re-runs the same dispatch attempt logic. Idempotency is preserved because the order keeps its
    // Idempotency_Key__c, and the attempt skips orders that were confirmed or cancelled in the meantime.
    public void execute(QueueableContext context) {
        new ProcurementDispatchQueueable(orderIds, attempt).execute(context);
    }

    // Queues the next attempt after an exponentially growing delay. The caller has already decided that the
    // attempt limit (Max_Dispatch_Attempts__c) is not reached, so retries are bounded by configuration.
    public static void scheduleRetry(List<Id> orderIds, Integer failedAttempt) {
        ProcurementConfig.Settings config = ProcurementConfig.get();
        if (failedAttempt >= config.maxDispatchAttempts) return;
        Integer delay = Math.min(MAX_DELAY_MINUTES, config.retryDelayMinutes * (Integer) Math.pow(2, failedAttempt - 1));

        if (Test.isRunningTest()) {
            RetryRequest request = new RetryRequest();
            request.orderIds = orderIds;
            request.nextAttempt = failedAttempt + 1;
            request.delayMinutes = delay;
            scheduledInTest.add(request);
            return;
        }
        System.enqueueJob(new IntegrationRetryQueueable(orderIds, failedAttempt + 1), delay);
    }
}
