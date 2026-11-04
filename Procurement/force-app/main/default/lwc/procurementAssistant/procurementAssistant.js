import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import isAIConfigured from '@salesforce/apex/ProcurementAIService.isAIConfigured';
import getReorderRecommendations from '@salesforce/apex/ProcurementAIService.getReorderRecommendations';
import getSupplierRecommendationsForProduct from '@salesforce/apex/ProcurementAIService.getSupplierRecommendationsForProduct';

export default class ProcurementAssistant extends NavigationMixin(LightningElement) {
    @track isConfigured = false;
    @track reorderRecs = [];
    @track supplierRecs = [];
    @track isLoadingReorder = false;
    @track reorderError = null;
    @track selectedProductId = null;

    connectedCallback() {
        this.loadAIStatus();
        this.loadReorderRecs();
    }

    loadAIStatus() {
        isAIConfigured()
            .then(result => { this.isConfigured = result; })
            .catch(() => { this.isConfigured = false; });
    }

    loadReorderRecs() {
        this.isLoadingReorder = true;
        this.reorderError = null;
        getReorderRecommendations()
            .then(data => {
                this.reorderRecs = data.map(r => ({
                    ...r,
                    cardStyle: r.urgency === 'High'
                        ? 'border-left: 4px solid #c23934;'
                        : 'border-left: 4px solid #ff9900;'
                }));
                this.isLoadingReorder = false;
            })
            .catch(err => {
                this.reorderError = err.body ? err.body.message : 'Error loading recommendations';
                this.isLoadingReorder = false;
            });
    }

    handleProductChange(event) {
        this.selectedProductId = event.detail.recordId;
        if (!this.selectedProductId) { this.supplierRecs = []; return; }
        getSupplierRecommendationsForProduct({ productId: this.selectedProductId })
            .then(data => { this.supplierRecs = data; })
            .catch(() => { this.supplierRecs = []; });
    }

    handleViewRecord(event) {
        const id = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: id, actionName: 'view' }
        });
    }

    handleRefresh() { this.loadReorderRecs(); }

    get hasReorderRecs() { return !this.isLoadingReorder && this.reorderRecs.length > 0; }
    get reorderEmpty() { return !this.isLoadingReorder && !this.reorderError && this.reorderRecs.length === 0; }
    get hasSupplierRecs() { return this.supplierRecs.length > 0; }
}
