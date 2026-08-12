@IsTest
private class MAS_CFE_UtilsTest {
    @IsTest
    static void resolveBatchSizeFallsBackToDefaultWhenUnsetOrOutOfRange() {
        Assert.areEqual(MAS_CFE_Utils.DEFAULT_BATCH_SIZE, MAS_CFE_Utils.resolveBatchSize(null), 'Null falls back to default');
        Assert.areEqual(MAS_CFE_Utils.DEFAULT_BATCH_SIZE, MAS_CFE_Utils.resolveBatchSize(0), 'Zero falls back to default');
        Assert.areEqual(MAS_CFE_Utils.DEFAULT_BATCH_SIZE, MAS_CFE_Utils.resolveBatchSize(-5), 'Negative falls back to default');
    }

    @IsTest
    static void resolveBatchSizeCapsAtMax() {
        Assert.areEqual(MAS_CFE_Utils.MAX_BATCH_SIZE, MAS_CFE_Utils.resolveBatchSize(200), 'Exactly the max is preserved');
        Assert.areEqual(MAS_CFE_Utils.MAX_BATCH_SIZE, MAS_CFE_Utils.resolveBatchSize(250), 'Above the max is capped');
    }

    @IsTest
    static void resolveBatchSizeTruncatesDecimalValues() {
        Assert.areEqual(75, MAS_CFE_Utils.resolveBatchSize(75.6), 'Decimal values truncate to an Integer');
    }

    @IsTest
    static void toActionTypeMapsApexAndFlow() {
        Assert.areEqual('apex', MAS_CFE_Utils.toActionType('Apex'), 'Apex target type maps to the apex action type');
        Assert.areEqual('flow', MAS_CFE_Utils.toActionType('Flow'), 'Flow target type maps to the flow action type');
        Assert.areEqual('flow', MAS_CFE_Utils.toActionType(null), 'Anything other than Apex defaults to flow');
    }

    @IsTest
    static void getFieldValueHandlesBlankInputsAndSimpleFields() {
        Assert.areEqual(null, MAS_CFE_Utils.getFieldValue(null, 'Name'), 'Null record returns null');
        Assert.areEqual(null, MAS_CFE_Utils.getFieldValue(new Account(Name = 'Test'), null), 'Blank field path returns null');
        Assert.areEqual('Direct Field', MAS_CFE_Utils.getFieldValue(new Account(Name = 'Direct Field'), 'Name'),
            'A simple (non-dotted) field path resolves directly');
    }

    @IsTest
    static void getFieldValueTraversesDottedParentPaths() {
        Account parentAcct = new Account(Name = 'Parent Co');
        Contact withParent = new Contact(LastName = 'Test');
        withParent.putSObject('Account', parentAcct);
        Assert.areEqual('Parent Co', MAS_CFE_Utils.getFieldValue(withParent, 'Account.Name'),
            'A dotted path traverses to the related parent record');

        Contact withoutParent = new Contact(LastName = 'Orphan');
        Assert.areEqual(null, MAS_CFE_Utils.getFieldValue(withoutParent, 'Account.Name'),
            'A missing parent partway through the traversal returns null instead of throwing');
    }

    @IsTest
    static void describeCronReturnsBlankForBlankInput() {
        Assert.areEqual('', MAS_CFE_Utils.describeCron(null), 'Null cron describes as blank');
        Assert.areEqual('', MAS_CFE_Utils.describeCron(''), 'Blank cron describes as blank');
    }

    @IsTest
    static void describeCronRecognizesHourly() {
        Assert.areEqual('Every hour', MAS_CFE_Utils.describeCron('0 0 * * * ?'));
    }

    @IsTest
    static void describeCronRecognizesDailyWithAmPmFormatting() {
        Assert.areEqual('Daily at 6:00 AM', MAS_CFE_Utils.describeCron('0 0 6 * * ?'));
        Assert.areEqual('Daily at 12:00 AM', MAS_CFE_Utils.describeCron('0 0 0 * * ?'), 'Hour 0 formats as 12 AM');
        Assert.areEqual('Daily at 12:30 PM', MAS_CFE_Utils.describeCron('0 30 12 * * ?'), 'Hour 12 formats as 12 PM');
        Assert.areEqual('Daily at 11:05 PM', MAS_CFE_Utils.describeCron('0 5 23 * * ?'));
    }

    @IsTest
    static void describeCronRecognizesWeekly() {
        Assert.areEqual('Weekly on MON at 6:00 AM', MAS_CFE_Utils.describeCron('0 0 6 ? * MON'));
        Assert.areEqual('Weekly on MON,WED,FRI at 6:00 AM', MAS_CFE_Utils.describeCron('0 0 6 ? * MON,WED,FRI'));
    }

    @IsTest
    static void describeCronRecognizesMonthly() {
        Assert.areEqual('Monthly on day 1 at 6:00 AM', MAS_CFE_Utils.describeCron('0 0 6 1 * ?'));
        Assert.areEqual('Monthly on the last day at 6:00 AM', MAS_CFE_Utils.describeCron('0 0 6 L * ?'));
    }

    @IsTest
    static void describeCronFallsBackToRawExpressionForCustomShapes() {
        String custom = '0 15 10 ? * 6#3';
        Assert.areEqual(custom, MAS_CFE_Utils.describeCron(custom), 'An unrecognized cron shape returns the raw expression');

        String malformed = 'not a cron';
        Assert.areEqual(malformed, MAS_CFE_Utils.describeCron(malformed), 'A malformed cron (wrong token count) returns the raw string');
    }
}
