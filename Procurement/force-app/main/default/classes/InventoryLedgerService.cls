public with sharing class InventoryLedgerService {

    public class LedgerException extends Exception {}

    private static final Set<String> TRANSACTION_TYPES = new Set<String>{
        'Receipt', 'Issue', 'Adjustment', 'Transfer In', 'Transfer Out', 'Reversal'
    };

    public class LedgerEntry {
        public Id inventoryId;
        public Id productId;
        public Id warehouseId;
        public String transactionType;
        public Decimal quantityChange;
        public Decimal onOrderChange;
        public String transactionKey;
        public Id sourceReceiptLineId;
        public Id sourceOrderLineId;
        public String label;
        public String notes;
    }

    // Transaction keys that were already posted. Callers use this to report a duplicate posting
    // with their own wording before any stock is touched.
    public static Set<String> findExistingKeys(Set<String> keys) {
        Set<String> existing = new Set<String>();
        if (keys == null || keys.isEmpty()) return existing;
        for (Inventory_Transaction__c tx : [
            SELECT Transaction_Key__c FROM Inventory_Transaction__c WHERE Transaction_Key__c IN :keys
        ]) {
            existing.add(tx.Transaction_Key__c);
        }
        return existing;
    }

    // Applies all entries to stock and writes one ledger row per entry. Inventory rows are locked
    // (FOR UPDATE) for the duration of the caller's transaction, balances are calculated sequentially per
    // inventory record, and a repeated transaction key is rejected. There is no savepoint here on purpose:
    // the caller owns the transaction so stock, ledger and order updates commit or roll back together.
    public static List<Inventory_Transaction__c> post(List<LedgerEntry> entries) {
        List<Inventory_Transaction__c> posted = new List<Inventory_Transaction__c>();
        if (entries == null || entries.isEmpty()) return posted;
        if (!Schema.sObjectType.Inventory_Transaction__c.isCreateable() || !Schema.sObjectType.Inventory__c.isUpdateable()) {
            throw new LedgerException('You do not have permission to record inventory movements.');
        }

        Set<String> keys = new Set<String>();
        Set<Id> inventoryIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();
        Set<Id> warehouseIds = new Set<Id>();
        for (LedgerEntry entry : entries) {
            validateEntry(entry);
            if (!keys.add(entry.transactionKey)) {
                throw new LedgerException('Duplicate inventory transaction key in the same posting: ' + entry.transactionKey);
            }
            if (entry.inventoryId != null) {
                inventoryIds.add(entry.inventoryId);
            } else {
                productIds.add(entry.productId);
                warehouseIds.add(entry.warehouseId);
            }
        }
        if (!findExistingKeys(keys).isEmpty()) {
            throw new LedgerException('This inventory movement has already been posted.');
        }

        Map<Id, Inventory__c> byId = new Map<Id, Inventory__c>();
        Map<String, Inventory__c> byLocation = new Map<String, Inventory__c>();
        for (Inventory__c inv : [
            SELECT Id, Product__c, Warehouse__c, On_Hand__c, On_Order__c
            FROM Inventory__c
            WHERE Id IN :inventoryIds OR (Product__c IN :productIds AND Warehouse__c IN :warehouseIds)
            FOR UPDATE
        ]) {
            byId.put(inv.Id, inv);
            byLocation.put(inv.Product__c + '|' + inv.Warehouse__c, inv);
        }

        Map<Id, Decimal> runningOnHand = new Map<Id, Decimal>();
        for (LedgerEntry entry : entries) {
            Inventory__c inv = entry.inventoryId != null
                ? byId.get(entry.inventoryId)
                : byLocation.get(entry.productId + '|' + entry.warehouseId);
            if (inv == null) {
                throw new LedgerException('No inventory record exists for ' + (String.isNotBlank(entry.label) ? entry.label : 'the product') + ' in the receiving warehouse.');
            }
            Decimal before = runningOnHand.containsKey(inv.Id) ? runningOnHand.get(inv.Id) : nz(inv.On_Hand__c);
            Decimal after = before + entry.quantityChange;
            if (after < 0) {
                throw new LedgerException('Insufficient stock for ' + (String.isNotBlank(entry.label) ? entry.label : 'the product') + ': on hand ' + before + ', change ' + entry.quantityChange + '.');
            }
            runningOnHand.put(inv.Id, after);
            inv.On_Hand__c = after;
            if (entry.onOrderChange != null && inv.On_Order__c != null) {
                inv.On_Order__c = Math.max(0, inv.On_Order__c + entry.onOrderChange);
            }

            posted.add(new Inventory_Transaction__c(
                Inventory__c = inv.Id,
                Product__c = inv.Product__c,
                Warehouse__c = inv.Warehouse__c,
                Transaction_Type__c = entry.transactionType,
                Quantity_Change__c = entry.quantityChange,
                Quantity_Before__c = before,
                Quantity_After__c = after,
                Source_Receipt_Line__c = entry.sourceReceiptLineId,
                Source_Order_Line__c = entry.sourceOrderLineId,
                Transaction_Key__c = entry.transactionKey,
                Notes__c = entry.notes,
                Processed_At__c = Datetime.now(),
                Processed_By__c = UserInfo.getUserId()
            ));
        }

        // Stock is derived from the ledger, so it is written with fresh records rather than the locked rows.
        List<Inventory__c> stockUpdates = new List<Inventory__c>();
        for (Id invId : runningOnHand.keySet()) {
            Inventory__c locked = byId.get(invId);
            stockUpdates.add(new Inventory__c(Id = invId, On_Hand__c = locked.On_Hand__c, On_Order__c = locked.On_Order__c));
        }
        update stockUpdates;
        insert posted;
        return posted;
    }

    private static void validateEntry(LedgerEntry entry) {
        if (entry == null) throw new LedgerException('An inventory movement is required.');
        if (String.isBlank(entry.transactionKey)) throw new LedgerException('Every inventory movement needs a transaction key.');
        if (String.isBlank(entry.transactionType) || !TRANSACTION_TYPES.contains(entry.transactionType)) {
            throw new LedgerException('Unsupported inventory transaction type: ' + entry.transactionType);
        }
        if (entry.quantityChange == null || entry.quantityChange == 0) {
            throw new LedgerException('An inventory movement needs a non-zero quantity.');
        }
        if (entry.inventoryId == null && (entry.productId == null || entry.warehouseId == null)) {
            throw new LedgerException('An inventory movement needs an inventory record, or a product and a warehouse.');
        }
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }
}
