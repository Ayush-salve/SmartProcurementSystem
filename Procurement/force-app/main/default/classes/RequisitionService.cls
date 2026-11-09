public with sharing class RequisitionService {

    public class RequisitionWrapper {
        @AuraEnabled public Purchase_Requisition__c requisition;
        @AuraEnabled public List<Requisition_Line__c> lines;
        @AuraEnabled public Decimal estimatedTotal;
        @AuraEnabled public Boolean isEditable;
    }

    private static final Set<String> EDITABLE_STATUSES = new Set<String>{'Draft'};
    private static final Set<String> SUBMITTABLE_STATUSES = new Set<String>{'Draft', 'Submitted'};

    public class SubmissionRequest {
        @InvocableVariable(label='Requisition Id' required=true)
        public Id requisitionId;
    }

    public class SubmissionResult {
        @InvocableVariable(label='Requisition Id')
        public Id requisitionId;
        @InvocableVariable(label='Is Valid')
        public Boolean isValid;
        @InvocableVariable(label='Message')
        public String message;
        @InvocableVariable(label='Line Count')
        public Integer lineCount;
        @InvocableVariable(label='Estimated Total')
        public Decimal estimatedTotal;
    }

    @InvocableMethod(
        label='Validate Requisition For Submission'
        description='Validates a requisition and its lines and calculates the authoritative estimated total. Returns a result per requisition instead of throwing.'
    )
    public static List<SubmissionResult> validateForSubmission(List<SubmissionRequest> requests) {
        Set<Id> ids = new Set<Id>();
        for (SubmissionRequest r : requests) {
            if (r.requisitionId != null) ids.add(r.requisitionId);
        }
        Map<Id, Purchase_Requisition__c> reqMap = new Map<Id, Purchase_Requisition__c>([
            SELECT Id, Required_By__c,
                   (SELECT Id, Product__c, Requested_Qty__c, Estimated_Unit_Price__c, Estimated_Line_Total__c
                    FROM Requisition_Lines__r)
            FROM Purchase_Requisition__c WHERE Id IN :ids WITH USER_MODE
        ]);

        List<SubmissionResult> results = new List<SubmissionResult>();
        for (SubmissionRequest r : requests) {
            SubmissionResult res = new SubmissionResult();
            res.requisitionId = r.requisitionId;
            res.isValid = false;
            res.lineCount = 0;
            res.estimatedTotal = 0;
            Purchase_Requisition__c req = reqMap.get(r.requisitionId);
            if (req == null) {
                res.message = 'Requisition not found or not accessible.';
            } else {
                res.message = validateRequisition(req, res);
                res.isValid = res.message == null;
                if (res.isValid) res.message = 'Requisition is valid.';
            }
            results.add(res);
        }
        return results;
    }

    // Returns an error message, or null when valid. Populates line count and total on the result.
    private static String validateRequisition(Purchase_Requisition__c req, SubmissionResult res) {
        return validateSubmissionData(req.Required_By__c, req.Requisition_Lines__r, res);
    }

    // Single implementation of the submission rules, shared by the validation invocable (used by the
    // Requisition_Submission flow) and by RequisitionTrigger.
    private static String validateSubmissionData(Date requiredBy, List<Requisition_Line__c> lines, SubmissionResult res) {
        res.lineCount = lines.size();
        if (lines.isEmpty()) {
            return 'Add at least one requisition line before submitting.';
        }
        if (requiredBy != null && requiredBy < Date.today()) {
            return 'Required By date cannot be in the past.';
        }
        Decimal total = 0;
        for (Requisition_Line__c line : lines) {
            if (line.Product__c == null) {
                return 'Every requisition line must have a product.';
            }
            if (line.Requested_Qty__c == null || line.Requested_Qty__c <= 0) {
                return 'Every requisition line must have a requested quantity greater than zero.';
            }
            if (line.Estimated_Unit_Price__c == null || line.Estimated_Unit_Price__c < 0) {
                return 'Every requisition line must have a non-negative estimated unit price.';
            }
            total += line.Requested_Qty__c * line.Estimated_Unit_Price__c;
        }
        res.estimatedTotal = total;
        return null;
    }

    private static final Map<String, Set<String>> STATUS_TRANSITIONS = new Map<String, Set<String>>{
        'Draft' => new Set<String>{'Submitted', 'Cancelled'},
        'Submitted' => new Set<String>{'Under Review', 'Approved', 'Rejected', 'Draft', 'Cancelled'},
        'Under Review' => new Set<String>{'Approved', 'Rejected', 'Draft', 'Cancelled'},
        'Approved' => new Set<String>{'Partially Ordered', 'Ordered', 'Cancelled'},
        'Partially Ordered' => new Set<String>{'Ordered', 'Cancelled'},
        'Rejected' => new Set<String>{'Draft'},
        'Ordered' => new Set<String>(),
        'Cancelled' => new Set<String>()
    };

    public static Boolean isValidTransition(String fromStatus, String toStatus) {
        String origin = String.isBlank(fromStatus) ? 'Draft' : fromStatus;
        Set<String> allowed = STATUS_TRANSITIONS.get(origin);
        return allowed != null && allowed.contains(toStatus);
    }

    // Used by RequisitionTrigger (before update): rejects status jumps and applies the submission rules
    // when a requisition moves to Submitted.
    public static void enforceTransitionsAndSubmissionRules(List<Purchase_Requisition__c> newList, Map<Id, Purchase_Requisition__c> oldMap) {
        List<Purchase_Requisition__c> submitting = new List<Purchase_Requisition__c>();
        for (Purchase_Requisition__c req : newList) {
            Purchase_Requisition__c old = oldMap.get(req.Id);
            if (old == null || req.Status__c == old.Status__c) continue;
            if (!isValidTransition(old.Status__c, req.Status__c)) {
                req.addError('A requisition cannot move from ' + old.Status__c + ' to ' + req.Status__c + '.');
                continue;
            }
            if (req.Status__c == 'Submitted') submitting.add(req);
        }
        if (submitting.isEmpty()) return;

        Map<Id, List<Requisition_Line__c>> linesByRequisition = new Map<Id, List<Requisition_Line__c>>();
        for (Requisition_Line__c line : [
            SELECT Requisition__c, Product__c, Requested_Qty__c, Estimated_Unit_Price__c
            FROM Requisition_Line__c WHERE Requisition__c IN :new Map<Id, Purchase_Requisition__c>(submitting).keySet()
        ]) {
            if (!linesByRequisition.containsKey(line.Requisition__c)) linesByRequisition.put(line.Requisition__c, new List<Requisition_Line__c>());
            linesByRequisition.get(line.Requisition__c).add(line);
        }
        for (Purchase_Requisition__c req : submitting) {
            List<Requisition_Line__c> lines = linesByRequisition.containsKey(req.Id) ? linesByRequisition.get(req.Id) : new List<Requisition_Line__c>();
            String error = validateSubmissionData(req.Required_By__c, lines, new SubmissionResult());
            if (error != null) req.addError(error);
        }
    }

    @AuraEnabled(cacheable=true)
    public static RequisitionWrapper getRequisitionWithLines(Id requisitionId) {
        try {
            Purchase_Requisition__c req = [
                SELECT Id, Name, Status__c, Requester__c, Requester__r.Name, Request_Date__c,
                       Required_By__c, Destination_Warehouse__c, Destination_Warehouse__r.Name,
                       Priority__c, Reason__c, Estimated_Total__c, Approved_Total__c,
                       Approval_Required__c, Submitted_At__c, Approved_At__c,
                       Rejection_Reason__c, Source__c, Idempotency_Key__c
                FROM Purchase_Requisition__c WHERE Id = :requisitionId LIMIT 1
            ];
            List<Requisition_Line__c> lines = [
                SELECT Id, Name, Product__c, Product__r.Name, Inventory__c, Requested_Qty__c,
                       Approved_Qty__c, Estimated_Unit_Price__c, Approved_Unit_Price__c,
                       Estimated_Line_Total__c, Approved_Line_Total__c,
                       Preferred_Supplier_Product__c, Line_Notes__c
                FROM Requisition_Line__c WHERE Requisition__c = :requisitionId
                ORDER BY Name
            ];
            RequisitionWrapper w = new RequisitionWrapper();
            w.requisition = req;
            w.lines = lines;
            w.isEditable = EDITABLE_STATUSES.contains(req.Status__c);
            Decimal total = 0;
            for (Requisition_Line__c line : lines) {
                if (line.Estimated_Line_Total__c != null) total += line.Estimated_Line_Total__c;
            }
            w.estimatedTotal = total;
            return w;
        } catch (Exception e) {
            throw auraError('Error loading requisition: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Id saveRequisition(String requisitionJson, String linesJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            Purchase_Requisition__c requisition = (Purchase_Requisition__c) JSON.deserialize(requisitionJson, Purchase_Requisition__c.class);
            List<Requisition_Line__c> lines = (List<Requisition_Line__c>) JSON.deserialize(linesJson, List<Requisition_Line__c>.class);

            if (requisition.Id == null) {
                if (String.isBlank(requisition.Source__c)) requisition.Source__c = 'Manual';
                if (requisition.Request_Date__c == null) requisition.Request_Date__c = Date.today();
                if (String.isBlank(requisition.Status__c)) requisition.Status__c = 'Draft';
                insert requisition;
            } else {
                // Guard: only allow edit if Draft
                Purchase_Requisition__c existing = [SELECT Status__c FROM Purchase_Requisition__c WHERE Id = :requisition.Id LIMIT 1];
                if (!EDITABLE_STATUSES.contains(existing.Status__c)) {
                    throw auraError('Cannot edit a requisition with status: ' + existing.Status__c);
                }
                update requisition;
            }

            // Fetch existing lines to detect deletions
            Set<Id> incomingIds = new Set<Id>();
            for (Requisition_Line__c l : lines) { if (l.Id != null) incomingIds.add(l.Id); }

            List<Requisition_Line__c> existingLines = [SELECT Id FROM Requisition_Line__c WHERE Requisition__c = :requisition.Id];
            List<Requisition_Line__c> toDelete = new List<Requisition_Line__c>();
            for (Requisition_Line__c el : existingLines) {
                if (!incomingIds.contains(el.Id)) toDelete.add(el);
            }
            if (!toDelete.isEmpty()) delete toDelete;

            List<Requisition_Line__c> toInsert = new List<Requisition_Line__c>();
            List<Requisition_Line__c> toUpdate = new List<Requisition_Line__c>();
            for (Requisition_Line__c line : lines) {
                line.Requisition__c = requisition.Id;
                if (line.Id == null) { toInsert.add(line); } else { toUpdate.add(line); }
            }
            if (!toInsert.isEmpty()) insert toInsert;
            if (!toUpdate.isEmpty()) update toUpdate;

            return requisition.Id;
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw auraError('Error saving requisition: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void submitRequisitionForApproval(Id requisitionId) {
        try {
            Purchase_Requisition__c req = [SELECT Id, Status__c FROM Purchase_Requisition__c WHERE Id = :requisitionId LIMIT 1];
            if (!SUBMITTABLE_STATUSES.contains(req.Status__c)) {
                throw auraError('Requisition cannot be submitted from status: ' + req.Status__c);
            }
            req.Status__c = 'Submitted';
            req.Submitted_At__c = Datetime.now();
            req.Approval_Required__c = true;
            update req;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError('Error submitting requisition: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Purchase_Requisition__c> getRecentRequisitions(Integer limitCount) {
        try {
            Integer lim = (limitCount != null && limitCount > 0) ? limitCount : 20;
            return [SELECT Id, Name, Status__c, Requester__r.Name, Request_Date__c, Required_By__c,
                           Priority__c, Estimated_Total__c, Destination_Warehouse__r.Name
                    FROM Purchase_Requisition__c
                    ORDER BY CreatedDate DESC LIMIT :lim];
        } catch (Exception e) {
            throw auraError('Error loading requisitions: ' + e.getMessage());
        }
    }

    // AuraHandledException hides its message from callers unless setMessage is used.
    private static AuraHandledException auraError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
