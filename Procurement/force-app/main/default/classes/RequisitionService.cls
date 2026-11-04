public with sharing class RequisitionService {

    public class RequisitionWrapper {
        @AuraEnabled public Purchase_Requisition__c requisition;
        @AuraEnabled public List<Requisition_Line__c> lines;
        @AuraEnabled public Decimal estimatedTotal;
        @AuraEnabled public Boolean isEditable;
    }

    private static final Set<String> EDITABLE_STATUSES = new Set<String>{'Draft'};
    private static final Set<String> SUBMITTABLE_STATUSES = new Set<String>{'Draft', 'Submitted'};

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
            throw new AuraHandledException('Error loading requisition: ' + e.getMessage());
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
                    throw new AuraHandledException('Cannot edit a requisition with status: ' + existing.Status__c);
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
            throw new AuraHandledException('Error saving requisition: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void submitRequisitionForApproval(Id requisitionId) {
        try {
            Purchase_Requisition__c req = [SELECT Id, Status__c FROM Purchase_Requisition__c WHERE Id = :requisitionId LIMIT 1];
            if (!SUBMITTABLE_STATUSES.contains(req.Status__c)) {
                throw new AuraHandledException('Requisition cannot be submitted from status: ' + req.Status__c);
            }
            req.Status__c = 'Submitted';
            req.Submitted_At__c = Datetime.now();
            req.Approval_Required__c = true;
            update req;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error submitting requisition: ' + e.getMessage());
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
            throw new AuraHandledException('Error loading requisitions: ' + e.getMessage());
        }
    }
}
