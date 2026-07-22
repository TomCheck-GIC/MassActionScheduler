trigger MAS_ConfigurationTrigger on MAS_Configuration__c (before insert, before update) {
    MAS_Utils.syncScheduleDescription(Trigger.new);
}
