trigger MAS_GIC_ConfigurationTrigger on MAS_GIC_Configuration__c (before insert, before update) {
    MAS_GIC_Utils.syncScheduleDescription(Trigger.new);
}
