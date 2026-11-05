import { LightningElement, api, track } from 'lwc';
import getSupplierOffersForProduct from '@salesforce/apex/SupplierComparisonService.getSupplierOffersForProduct';

export default class SupplierComparison extends LightningElement {
    @api productId = null;
    @track selectedProductId = null;
    @track supplierOffers = [];
    @track selectedOffer = null;
    @track isLoading = false;
    @track error = null;

    connectedCallback() {
        if (this.productId) {
            this.selectedProductId = this.productId;
            this.loadSupplierOffers();
        }
    }

    handleProductChange(event) {
        this.selectedProductId = event.detail.recordId;
        this.supplierOffers = [];
        this.selectedOffer = null;
        this.error = null;
    }

    loadSupplierOffers() {
        if (!this.selectedProductId) return;
        this.isLoading = true;
        this.error = null;
        this.supplierOffers = [];
        getSupplierOffersForProduct({ productId: this.selectedProductId })
            .then(data => {
                this.supplierOffers = data.map(offer => ({
                    ...offer,
                    rowClass: offer.isBestOffer ? 'slds-theme_success' : '',
                    selectVariant: offer.isBestOffer ? 'brand' : 'neutral',
                    selectLabel: this.selectedOffer && this.selectedOffer.supplierProductId === offer.supplierProductId
                        ? 'Selected ✓' : 'Select',
                    qualityRating: offer.qualityRating != null ? offer.qualityRating : '—',
                    deliveryRating: offer.deliveryRating != null ? offer.deliveryRating : '—',
                    sku: offer.sku || '—'
                }));
                this.isLoading = false;
            })
            .catch(err => {
                this.error = err.body ? err.body.message : 'Error loading supplier offers';
                this.isLoading = false;
            });
    }

    handleSelectSupplier(event) {
        const offerId = event.currentTarget.dataset.id;
        this.selectedOffer = this.supplierOffers.find(o => o.supplierProductId === offerId);
        // Update row labels
        this.supplierOffers = this.supplierOffers.map(o => ({
            ...o,
            selectLabel: o.supplierProductId === offerId ? 'Selected ✓' : 'Select',
            selectVariant: o.supplierProductId === offerId ? 'success' : (o.isBestOffer ? 'brand' : 'neutral')
        }));
        // Fire selection event for parent components
        this.dispatchEvent(new CustomEvent('supplierselected', {
            detail: {
                supplierProductId: this.selectedOffer.supplierProductId,
                supplierId: this.selectedOffer.supplierId,
                supplierName: this.selectedOffer.supplierName,
                unitPrice: this.selectedOffer.unitPrice
            },
            bubbles: true
        }));
    }

    get bestOffer() {
        return this.supplierOffers.find(o => o.isBestOffer) || null;
    }

    get hasOffers() {
        return !this.isLoading && !this.error && this.supplierOffers.length > 0;
    }

    get isEmpty() {
        return !this.isLoading && !this.error && this.selectedProductId && this.supplierOffers.length === 0;
    }
}
