/**
 * Sample invocable Apex target, usable as a demo target for a Mass Action
 * Scheduler configuration and as a testable action for the package tests.
 * It records the values it receives so tests can assert the mapping worked.
 */
public with sharing class MAS_SampleAction {
    @TestVisible
    public static List<String> capturedNames = new List<String>();

    public class Input {
        @InvocableVariable(label='Record Name')
        public String recordName;

        @InvocableVariable(label='Record Id')
        public Id recordId;
    }

    @InvocableMethod(label='MAS Sample Action' description='Sample target that captures the record name it is given.')
    public static List<String> run(List<Input> inputs) {
        List<String> results = new List<String>();
        for (Input item : inputs) {
            capturedNames.add(item.recordName);
            results.add('ok');
        }
        return results;
    }
}
