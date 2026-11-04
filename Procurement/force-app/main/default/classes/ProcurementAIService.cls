public with sharing class ProcurementAIService {

    public class AIRecommendation {
        @AuraEnabled public String type;
        @AuraEnabled public String title;
        @AuraEnabled public String description;
        @AuraEnabled public String urgency;
        @AuraEnabled public Id relatedRecordId;
        @AuraEnabled public String relatedRecordName;
        @AuraEnabled public Map<String, Object> metadata;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean isAIConfigured() {
        // Check if Agentforce/Einstein AI features are available
        // Returns false in this implementation since no AI service is wired
        return false;
    }

    @AuraEnabled(cacheable=true)
    public static List<AIRecommendation> getReorderRecommendations() {
        try {
            List<AIRecommendation> recs = new List<AIRecommendation>();
            List<Inventory__c> lowStock = [
                SELECT Id, Name, Product__c, Product__r.Name, Warehouse__r.Name,
                       Available_Stock__c, Reorder_Point__c, Reorder_Status__c,
                       Average_Daily_Demand__c, Lead_Time_Days__c
                FROM Inventory__c
                WHERE Reorder_Status__c IN ('Reorder Needed', 'At Risk')
                ORDER BY Available_Stock__c ASC NULLS FIRST
                LIMIT 50
            ];
            for (Inventory__c inv : lowStock) {
                AIRecommendation rec = new AIRecommendation();
                rec.type = 'Reorder';
                rec.relatedRecordId = inv.Id;
                rec.relatedRecordName = inv.Name;
                rec.urgency = inv.Reorder_Status__c == 'Reorder Needed' ? 'High' : 'Medium';
                Decimal suggested = 0;
                if (inv.Average_Daily_Demand__c != null && inv.Lead_Time_Days__c != null) {
                    suggested = inv.Average_Daily_Demand__c * inv.Lead_Time_Days__c * 1.5;
                }
                rec.title = 'Reorder: ' + (inv.Product__r != null ? inv.Product__r.Name : inv.Name);
                rec.description = 'Stock at ' + (inv.Available_Stock__c != null ? inv.Available_Stock__c : 0) +
                    ' units. Reorder point: ' + (inv.Reorder_Point__c != null ? inv.Reorder_Point__c : 0) +
                    (suggested > 0 ? '. Suggested qty: ' + suggested.setScale(0) : '');
                rec.metadata = new Map<String, Object>{
                    'suggestedQty' => suggested > 0 ? suggested.setScale(0) : null,
                    'warehouseName' => inv.Warehouse__r != null ? inv.Warehouse__r.Name : ''
                };
                recs.add(rec);
            }
            return recs;
        } catch (Exception e) {
            throw new AuraHandledException('Error loading reorder recommendations: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<AIRecommendation> getSupplierRecommendationsForProduct(Id productId) {
        try {
            List<AIRecommendation> recs = new List<AIRecommendation>();
            List<Supplier_Product__c> offers = [
                SELECT Id, Name, Supplier__r.Name, Unit_Price__c, Lead_Time_Days__c,
                       Quality_Rating__c, Delivery_Rating__c, Valid_Until__c
                FROM Supplier_Product__c WHERE Product__c = :productId AND Active__c = true
                ORDER BY Unit_Price__c ASC NULLS LAST LIMIT 5
            ];
            Integer rank = 1;
            for (Supplier_Product__c sp : offers) {
                AIRecommendation rec = new AIRecommendation();
                rec.type = 'SupplierRecommendation';
                rec.relatedRecordId = sp.Id;
                rec.relatedRecordName = sp.Supplier__r != null ? sp.Supplier__r.Name : sp.Name;
                rec.urgency = rank == 1 ? 'High' : 'Low';
                rec.title = 'Recommended Supplier #' + rank + ': ' + rec.relatedRecordName;
                rec.description = 'Price: ' + (sp.Unit_Price__c != null ? sp.Unit_Price__c : 0) +
                    ', Lead time: ' + (sp.Lead_Time_Days__c != null ? sp.Lead_Time_Days__c : 'N/A') + ' days' +
                    (sp.Quality_Rating__c != null ? ', Quality: ' + sp.Quality_Rating__c + '/5' : '');
                rec.metadata = new Map<String, Object>{ 'rank' => rank };
                recs.add(rec);
                rank++;
            }
            return recs;
        } catch (Exception e) {
            throw new AuraHandledException('Error loading supplier recommendations: ' + e.getMessage());
        }
    }
}
