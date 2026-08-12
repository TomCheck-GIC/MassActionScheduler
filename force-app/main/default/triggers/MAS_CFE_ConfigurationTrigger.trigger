trigger MAS_CFE_ConfigurationTrigger on MAS_CFE_Configuration__c (before insert, before update) {
    MAS_CFE_Utils.syncScheduleDescription(Trigger.new);
}
