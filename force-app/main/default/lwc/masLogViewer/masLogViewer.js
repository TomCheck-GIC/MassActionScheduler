import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getLogs from '@salesforce/apex/MAS_ConfigController.getLogs';

// Datatable columns for the log grid.
const COLUMNS = [
    {
        label: 'Timestamp',
        fieldName: 'Timestamp__c',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    },
    { label: 'Message Type', fieldName: 'Message_Type__c', type: 'text', fixedWidth: 130 },
    { label: 'Message', fieldName: 'Message__c', type: 'text', wrapText: true },
    { label: 'Processed', fieldName: 'Processed_Records__c', type: 'number', fixedWidth: 110 },
    { label: 'Failed', fieldName: 'Failed_Records__c', type: 'number', fixedWidth: 90 },
    {
        label: 'Success %',
        fieldName: 'Batch_Success_Percentage__c',
        type: 'percent',
        fixedWidth: 110,
        typeAttributes: { maximumFractionDigits: 1 }
    },
    {
        label: 'Details',
        fieldName: 'logUrl',
        type: 'url',
        // A real anchor (not a JS-driven row action), so ctrl/cmd-click,
        // middle-click, and "open link in new tab" all work as expected.
        typeAttributes: { label: 'View', target: '_self' },
        fixedWidth: 90
    }
];

export default class MasLogViewer extends LightningElement {
    /** MAS_Configuration__c record Id. */
    @api recordId;

    columns = COLUMNS;
    logs = [];
    error;
    isRefreshing = false;

    _wiredResult;

    // A run kicked off from the wizard (Run Now, or a scheduled job that fires
    // while this tab is already open) completes asynchronously after this
    // component's wire has already fetched - there's no push notification when
    // new MAS_Log__c rows land, so a manual refresh is the only way to see them
    // without reloading the whole page.
    @wire(getLogs, { configId: '$recordId' })
    wiredLogs(result) {
        this._wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.logs = data.map((row) => ({
                ...row,
                logUrl: `/lightning/r/MAS_Log__c/${row.Id}/view`,
                // percent type expects a fraction, so normalize 0-100 -> 0-1.
                Batch_Success_Percentage__c:
                    row.Batch_Success_Percentage__c != null
                        ? row.Batch_Success_Percentage__c / 100
                        : null
            }));
            this.error = undefined;
        } else if (error) {
            this.error =
                (error.body && error.body.message) || error.message || 'Unknown error';
            this.logs = [];
        }
    }

    get hasLogs() {
        return this.logs && this.logs.length > 0;
    }

    handleRefresh() {
        if (!this._wiredResult) {
            return;
        }
        this.isRefreshing = true;
        refreshApex(this._wiredResult).finally(() => {
            this.isRefreshing = false;
        });
    }
}
