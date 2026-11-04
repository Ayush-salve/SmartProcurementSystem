import { LightningElement, track } from 'lwc';
import isIntegrationLogConfigured from '@salesforce/apex/IntegrationMonitorService.isIntegrationLogConfigured';
import getIntegrationStatus from '@salesforce/apex/IntegrationMonitorService.getIntegrationStatus';

export default class IntegrationMonitor extends LightningElement {
    @track isConfigured = false;
    @track status = { pendingCount: 0, failedCount: 0, successCount: 0, message: '' };
    @track isLoading = true;
    @track configMessage = '';

    connectedCallback() { this.loadStatus(); }

    loadStatus() {
        this.isLoading = true;
        getIntegrationStatus()
            .then(data => {
                this.isConfigured = data.isConfigured;
                this.status = data;
                this.configMessage = data.message;
                this.isLoading = false;
            })
            .catch(() => {
                this.isConfigured = false;
                this.configMessage = 'Integration logging has not been configured.';
                this.isLoading = false;
            });
    }

    handleRefresh() { this.loadStatus(); }
}
