/**
 * Invocable action so a Flow, Process, or other automation can trigger a Mass
 * Action Scheduler configuration on demand, by record Id or by Developer Name.
 *
 * Runs `without sharing`: the configuration it launches must run as an admin
 * defined it, independent of the record-level sharing visibility of whichever
 * automation (and running user) happens to invoke this action.
 */
public without sharing class MAS_CFE_RunConfigInvocable {
    public class Request {
        @InvocableVariable(label='Configuration Id' description='Id of the MAS_CFE_Configuration__c to run.')
        public Id configId;

        @InvocableVariable(label='Configuration Developer Name' description='Developer_Name__c of the configuration to run (used when Configuration Id is blank).')
        public String developerName;

        @InvocableVariable(label='Batch Size Override' description='Optional scope size; falls back to the configuration batch size.')
        public Integer batchSize;
    }

    public class Response {
        @InvocableVariable(label='Batch Job Id')
        public Id jobId;

        @InvocableVariable(label='Error Message' description='Populated when the configuration could not be launched (unknown configuration, or this transaction already started the maximum number of async jobs it is allowed).')
        public String errorMessage;
    }

    // Test seam: lets a unit test simulate this transaction having already used
    // up (part of) its async-call budget, without actually launching that many
    // real batch jobs (which would collide with the org-wide flex queue limit).
    @TestVisible
    private static Integer testAsyncCallsAlreadyUsed = 0;

    @InvocableMethod(label='Run Mass Action Configuration' description='Launches a Mass Action Scheduler configuration batch by Id or Developer Name.')
    public static List<Response> run(List<Request> requests) {
        // Collect developer names so we can resolve Ids in a single query.
        Set<String> devNames = new Set<String>();
        for (Request req : requests) {
            if (req.configId == null && String.isNotBlank(req.developerName)) {
                devNames.add(req.developerName);
            }
        }
        Map<String, Id> idByDevName = new Map<String, Id>();
        if (!devNames.isEmpty()) {
            for (MAS_CFE_Configuration__c c : [
                SELECT Id, Developer_Name__c FROM MAS_CFE_Configuration__c WHERE Developer_Name__c IN :devNames
            ]) {
                idByDevName.put(c.Developer_Name__c, c.Id);
            }
        }

        // Preload batch sizes for configs that don't override it.
        Set<Id> configIds = new Set<Id>();
        for (Request req : requests) {
            Id cfgId = (req.configId != null) ? req.configId : idByDevName.get(req.developerName);
            if (cfgId != null) {
                configIds.add(cfgId);
            }
        }
        Map<Id, MAS_CFE_Configuration__c> configsById = new Map<Id, MAS_CFE_Configuration__c>([
            SELECT Id, Batch_Size__c FROM MAS_CFE_Configuration__c WHERE Id IN :configIds
        ]);

        // Each launched configuration consumes one of this transaction's async-call
        // slots (Database.executeBatch counts against Limits.getLimitAsyncCalls()).
        // A Flow that calls this action once per record in a bulk update can easily
        // exceed that in a single transaction, so once the budget is used up, any
        // remaining requests are skipped (not thrown) with an explanatory message.
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Id cfgId = (req.configId != null) ? req.configId : idByDevName.get(req.developerName);
            Response resp = new Response();
            if (cfgId == null || !configsById.containsKey(cfgId)) {
                resp.errorMessage = 'No matching Mass Action Scheduler configuration was found.';
            } else if (Limits.getAsyncCalls() + testAsyncCallsAlreadyUsed >= Limits.getLimitAsyncCalls()) {
                resp.errorMessage = 'Skipped: this transaction already reached its maximum of '
                    + Limits.getLimitAsyncCalls() + ' async job(s); run this configuration separately.';
            } else {
                Integer scopeSize = (req.batchSize != null && req.batchSize > 0)
                    ? MAS_CFE_Utils.resolveBatchSize(req.batchSize)
                    : MAS_CFE_Utils.resolveBatchSize(configsById.get(cfgId).Batch_Size__c);
                resp.jobId = Database.executeBatch(new MAS_CFE_BatchRunner(cfgId), scopeSize);
            }
            responses.add(resp);
        }
        return responses;
    }
}
