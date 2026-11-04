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

            // Calculate composite scores
            List<SupplierOfferWrapper> result = new List<SupplierOfferWrapper>();
            Decimal minPrice = null;
            Decimal maxPrice = null;
            for (Supplier_Product__c sp : offers) {
                if (sp.Unit_Price__c != null) {
                    if (minPrice == null || sp.Unit_Price__c < minPrice) minPrice = sp.Unit_Price__c;
                    if (maxPrice == null || sp.Unit_Price__c > maxPrice) maxPrice = sp.Unit_Price__c;
                }
            }

            for (Supplier_Product__c sp : offers) {
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

                // Composite score: quality(40%) + delivery(40%) + price_rank(20%)
                Decimal qualScore = (sp.Quality_Rating__c != null ? sp.Quality_Rating__c : 3) * 0.4;
                Decimal delScore = (sp.Delivery_Rating__c != null ? sp.Delivery_Rating__c : 3) * 0.4;
                Decimal priceScore = 0.0;
                if (sp.Unit_Price__c != null && maxPrice != null && maxPrice > minPrice) {
                    priceScore = ((maxPrice - sp.Unit_Price__c) / (maxPrice - minPrice)) * 0.2 * 5;
                } else {
                    priceScore = 0.5;
                }
                w.compositeScore = (qualScore + delScore + priceScore).setScale(2);
                result.add(w);
            }

            // Sort by composite score desc (simple bubble sort for small lists)
            for (Integer i = 0; i < result.size() - 1; i++) {
                for (Integer j = 0; j < result.size() - i - 1; j++) {
                    if (result[j].compositeScore < result[j+1].compositeScore) {
                        SupplierOfferWrapper temp = result[j];
                        result[j] = result[j+1];
                        result[j+1] = temp;
                    }
                }
            }

            if (!result.isEmpty()) result[0].isBestOffer = true;
            for (Integer i = 1; i < result.size(); i++) result[i].isBestOffer = false;

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
