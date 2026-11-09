public with sharing class SupplierScoringService {

    private static final Decimal DEFAULT_RATING = 3;
    private static final Decimal NEUTRAL_COMPONENT = 0.5;
    // Composite scores are expressed on the same 0-5 scale as the quality and delivery ratings.
    private static final Decimal MAX_SCORE = 5;

    public class ScoredOffer implements Comparable {
        public Supplier_Product__c offer;
        public Decimal compositeScore;
        public Integer rank;

        // Highest score first; ties go to the lower price, then the shorter lead time, then a stable Id order.
        public Integer compareTo(Object other) {
            ScoredOffer o = (ScoredOffer) other;
            if (compositeScore != o.compositeScore) return compositeScore > o.compositeScore ? -1 : 1;
            Decimal p1 = offer.Unit_Price__c == null ? 999999999 : offer.Unit_Price__c;
            Decimal p2 = o.offer.Unit_Price__c == null ? 999999999 : o.offer.Unit_Price__c;
            if (p1 != p2) return p1 < p2 ? -1 : 1;
            Decimal l1 = offer.Lead_Time_Days__c == null ? 999999 : offer.Lead_Time_Days__c;
            Decimal l2 = o.offer.Lead_Time_Days__c == null ? 999999 : o.offer.Lead_Time_Days__c;
            if (l1 != l2) return l1 < l2 ? -1 : 1;
            if (offer.Id == null || o.offer.Id == null) return 0;
            return String.valueOf(offer.Id).compareTo(String.valueOf(o.offer.Id));
        }
    }

    // Pure calculation (no SOQL/DML). Offers are normalised per product, because prices and lead times
    // of different products are not comparable. Returned lists are ranked best first.
    public static Map<Id, List<ScoredOffer>> rankByProduct(List<Supplier_Product__c> offers) {
        ProcurementConfig.Settings cfg = ProcurementConfig.get();
        Decimal totalWeight = cfg.priceWeight + cfg.qualityWeight + cfg.deliveryWeight + cfg.leadTimeWeight;

        Map<Id, List<Supplier_Product__c>> byProduct = new Map<Id, List<Supplier_Product__c>>();
        for (Supplier_Product__c sp : offers) {
            if (!byProduct.containsKey(sp.Product__c)) byProduct.put(sp.Product__c, new List<Supplier_Product__c>());
            byProduct.get(sp.Product__c).add(sp);
        }

        Map<Id, List<ScoredOffer>> result = new Map<Id, List<ScoredOffer>>();
        for (Id productId : byProduct.keySet()) {
            List<Supplier_Product__c> productOffers = byProduct.get(productId);
            Decimal minPrice = null, maxPrice = null, minLead = null, maxLead = null;
            for (Supplier_Product__c sp : productOffers) {
                if (sp.Unit_Price__c != null) {
                    if (minPrice == null || sp.Unit_Price__c < minPrice) minPrice = sp.Unit_Price__c;
                    if (maxPrice == null || sp.Unit_Price__c > maxPrice) maxPrice = sp.Unit_Price__c;
                }
                if (sp.Lead_Time_Days__c != null) {
                    if (minLead == null || sp.Lead_Time_Days__c < minLead) minLead = sp.Lead_Time_Days__c;
                    if (maxLead == null || sp.Lead_Time_Days__c > maxLead) maxLead = sp.Lead_Time_Days__c;
                }
            }

            List<ScoredOffer> scored = new List<ScoredOffer>();
            for (Supplier_Product__c sp : productOffers) {
                Decimal quality = (sp.Quality_Rating__c == null ? DEFAULT_RATING : sp.Quality_Rating__c) / MAX_SCORE;
                Decimal delivery = (sp.Delivery_Rating__c == null ? DEFAULT_RATING : sp.Delivery_Rating__c) / MAX_SCORE;
                Decimal price = lowerIsBetter(sp.Unit_Price__c, minPrice, maxPrice);
                Decimal lead = lowerIsBetter(sp.Lead_Time_Days__c, minLead, maxLead);

                ScoredOffer so = new ScoredOffer();
                so.offer = sp;
                so.compositeScore = (MAX_SCORE * (
                    cfg.priceWeight * price + cfg.qualityWeight * quality +
                    cfg.deliveryWeight * delivery + cfg.leadTimeWeight * lead
                ) / totalWeight).setScale(2);
                scored.add(so);
            }
            scored.sort();
            for (Integer i = 0; i < scored.size(); i++) scored[i].rank = i + 1;
            result.put(productId, scored);
        }
        return result;
    }

    // Eligible = active, quoted price present, and not past the quote's validity date.
    public static List<Supplier_Product__c> getEligibleOffers(Set<Id> productIds) {
        if (productIds == null || productIds.isEmpty()) return new List<Supplier_Product__c>();
        Date today = Date.today();
        return [
            SELECT Id, Name, Supplier__c, Supplier__r.Name, Product__c, Unit_Price__c, Lead_Time_Days__c,
                   Minimum_Order_Qty__c, Maximum_Order_Qty__c, Quality_Rating__c, Delivery_Rating__c, Valid_Until__c
            FROM Supplier_Product__c
            WHERE Product__c IN :productIds AND Active__c = true AND Unit_Price__c != null
              AND (Valid_Until__c = null OR Valid_Until__c >= :today)
            WITH USER_MODE
            ORDER BY Product__c, Unit_Price__c
            LIMIT 2000
        ];
    }

    public static Map<Id, List<ScoredOffer>> rankEligibleOffers(Set<Id> productIds) {
        return rankByProduct(getEligibleOffers(productIds));
    }

    // First ranked offer whose order-quantity limits accept the requested quantity.
    public static ScoredOffer pickForQuantity(List<ScoredOffer> ranked, Decimal quantity) {
        if (ranked == null) return null;
        for (ScoredOffer so : ranked) {
            Boolean aboveMin = so.offer.Minimum_Order_Qty__c == null || quantity == null || quantity >= so.offer.Minimum_Order_Qty__c;
            Boolean belowMax = so.offer.Maximum_Order_Qty__c == null || quantity == null || quantity <= so.offer.Maximum_Order_Qty__c;
            if (aboveMin && belowMax) return so;
        }
        return null;
    }

    // 1 for the lowest value, 0 for the highest; neutral when the value is missing or all values are equal.
    private static Decimal lowerIsBetter(Decimal value, Decimal min, Decimal max) {
        if (value == null || min == null || max == null || max <= min) return NEUTRAL_COMPONENT;
        return (max - value) / (max - min);
    }
}
