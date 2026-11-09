trigger InventoryTrigger on Inventory__c (before insert, before update) {
    if (Trigger.isInsert) {
        InventoryTriggerHandler.beforeInsert(Trigger.new);
    } else {
        InventoryTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
    }
}
