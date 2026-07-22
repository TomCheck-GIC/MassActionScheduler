/**
 * Simple demo invocable action for testing the Mass Action Scheduler Apex
 * target picker. Not part of the packaged feature set - logs the account
 * name/Id it receives so a test run can be confirmed without side effects.
 */
public with sharing class Demo_LogAccountUpdate {
    public class Input {
        @InvocableVariable(label='Account Name')
        public String accountName;

        @InvocableVariable(label='Account Id')
        public Id accountId;
    }

    @InvocableMethod(label='Demo: Log Account Update' description='Demo target for testing the Mass Action Scheduler Apex picker - logs the account name/Id it receives.')
    public static List<String> run(List<Input> inputs) {
        List<String> results = new List<String>();
        for (Input item : inputs) {
            System.debug(LoggingLevel.INFO, 'Demo_LogAccountUpdate received: ' + item.accountName + ' (' + item.accountId + ')');
            results.add('logged');
        }
        return results;
    }
}
