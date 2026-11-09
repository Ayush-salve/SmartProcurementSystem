public with sharing class SupplierComparisonService {

    public class SupplierOfferWrapper {
        @AuraEnabled public Id supplierProductId;
        @AuraEnabled public Id supplierId;
        @AuraEnabled public String supplierName;
        @AuraEnabled public String sku;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal leadTimeDays;
        @AuraEnabled public Decimal minimumOrderQty;
        @AuraEnabled public Decimal maximumOrderQty;
        @AuraEnabled public Decimal qualityRating;
        @AuraEnabled public Decimal deliveryRating;
        @AuraEnabled public Decimal compositeScore;
        @AuraEnabled public Boolean isBestOffer;
        @AuraEnabled public Date validUntil;
        @AuraEnabled public Date lastQuoteDate;
    }

    @AuraEnabled(cacheable=true)
    public static List<SupplierOfferWrapper> getSupplierOffersForProduct(Id productId) {
        try {
            List<Supplier_Product__c> offers = [
                SELECT Id, Supplier__c, Supplier__r.Name, Product__c, Supplier_SKU__c,
                       Unit_Price__c, Lead_Time_Days__c, Minimum_Order_Qty__c, Maximum_Order_Qty__c,
                       Quality_Rating__c, Delivery_Rating__c, Valid_Until__c, Last_Quote_Date__c
                FROM Supplier_Product__c
                WHERE Product__c = :productId AND Active__c = true
                ORDER BY Unit_Price__c ASC NULLS LAST
            ];

            if (offers.isEmpty()) return new List<SupplierOfferWrapper>();

            // Ranking and weights come from SupplierScoringService (weights live in Procurement_Setting__mdt).
            List<SupplierOfferWrapper> result = new List<SupplierOfferWrapper>();
            Map<Id, List<SupplierScoringService.ScoredOffer>> ranked = SupplierScoringService.rankByProduct(offers);
            for (List<SupplierScoringService.ScoredOffer> productRanking : ranked.values()) {
                for (SupplierScoringService.ScoredOffer so : productRanking) {
                    Supplier_Product__c sp = so.offer;
                    SupplierOfferWrapper w = new SupplierOfferWrapper();
                    w.supplierProductId = sp.Id;
                    w.supplierId = sp.Supplier__c;
                    w.supplierName = sp.Supplier__r != null ? sp.Supplier__r.Name : '';
                    w.sku = sp.Supplier_SKU__c;
                    w.unitPrice = sp.Unit_Price__c;
                    w.leadTimeDays = sp.Lead_Time_Days__c;
                    w.minimumOrderQty = sp.Minimum_Order_Qty__c;
                    w.maximumOrderQty = sp.Maximum_Order_Qty__c;
                    w.qualityRating = sp.Quality_Rating__c;
                    w.deliveryRating = sp.Delivery_Rating__c;
                    w.validUntil = sp.Valid_Until__c;
                    w.lastQuoteDate = sp.Last_Quote_Date__c;
                    w.compositeScore = so.compositeScore;
                    w.isBestOffer = so.rank == 1;
                    result.add(w);
                }
            }

            return result;
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching supplier offers: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Supplier_Product__c> getActiveSupplierProductsForProduct(Id productId) {
        try {
            return [SELECT Id, Name, Supplier__c, Supplier__r.Name, Supplier_SKU__c, Unit_Price__c,
                           Lead_Time_Days__c, Minimum_Order_Qty__c, Quality_Rating__c, Delivery_Rating__c
                    FROM Supplier_Product__c WHERE Product__c = :productId AND Active__c = true
                    ORDER BY Unit_Price__c ASC NULLS LAST LIMIT 50];
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching supplier products: ' + e.getMessage());
        }
    }
}
