/**
 * Schedulable wrapper that launches a MAS_GIC_BatchRunner for a configuration.
 * Registered via System.schedule from MAS_GIC_ConfigController.saveSchedule.
 *
 * Runs `without sharing`: a scheduled run must process the configuration's full
 * result set as an admin defined it, independent of the running user context
 * the scheduled job executes under.
 */
public without sharing class MAS_GIC_Scheduler implements Schedulable {
    private final Id configId;

    public MAS_GIC_Scheduler(Id configId) {
        this.configId = configId;
    }

    public void execute(SchedulableContext sc) {
        MAS_GIC_Configuration__c cfg = [
            SELECT Id, Active__c, Batch_Size__c
            FROM MAS_GIC_Configuration__c
            WHERE Id = :configId
            LIMIT 1
        ];
        if (cfg.Active__c == true) {
            Database.executeBatch(new MAS_GIC_BatchRunner(configId), MAS_GIC_Utils.resolveBatchSize(cfg.Batch_Size__c));
        }
    }
}
