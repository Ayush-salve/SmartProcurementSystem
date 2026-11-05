import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

import getInventoryRecords from
    '@salesforce/apex/InventoryService.getInventoryRecords';

import getActiveWarehouses from
    '@salesforce/apex/InventoryService.getActiveWarehouses';

const PAGE_SIZE = 10;

const COLUMNS = [
    {
        label: 'Product',
        fieldName: 'productLink',
        type: 'url',
        typeAttributes: {
            label: { fieldName: 'productName' },
            target: '_self'
        }
    },
    {
        label: 'Warehouse',
        fieldName: 'warehouseName',
        sortable: true
    },
    {
        label: 'On Hand',
        fieldName: 'onHand',
        type: 'number',
        sortable: true
    },
    {
        label: 'Reserved',
        fieldName: 'reserved',
        type: 'number'
    },
    {
        label: 'Available',
        fieldName: 'available',
        type: 'number',
        sortable: true
    },
    {
        label: 'Reorder Point',
        fieldName: 'reorderPoint',
        type: 'number'
    },
    {
        label: 'Status',
        fieldName: 'reorderStatus'
    },
    {
        label: 'Last Check',
        fieldName: 'lastStockCheck',
        type: 'date',
        sortable: true
    },
    {
        type: 'action',
        typeAttributes: {
            rowActions: [
                { label: 'View Record', name: 'view' }
            ]
        }
    }
];

export default class InventoryOverview extends NavigationMixin(
    LightningElement
) {
    columns = COLUMNS;

    inventoryData = [];
    filteredData = [];

    isLoading = false;
    error = null;

    searchTerm = '';
    reorderStatusFilter = 'All';
    warehouseFilter = 'All';

    warehouseOptions = [
        { label: 'All Warehouses', value: 'All' }
    ];

    statusOptions = [
        { label: 'All Statuses', value: 'All' },
        { label: 'Reorder Needed', value: 'Reorder Needed' },
        { label: 'At Risk', value: 'At Risk' },
        { label: 'Healthy', value: 'Healthy' }
    ];

    sortedBy = 'available';
    sortedDirection = 'asc';

    currentPage = 1;
    searchTimeout;

    connectedCallback() {
        this.loadWarehouses();
        this.loadInventory();
    }

    disconnectedCallback() {
        clearTimeout(this.searchTimeout);
    }

    async loadWarehouses() {
        try {
            const data = await getActiveWarehouses();

            this.warehouseOptions = [
                { label: 'All Warehouses', value: 'All' },
                ...(data || []).map(warehouse => ({
                    label: warehouse.Name,
                    value: warehouse.Id
                }))
            ];
        } catch (error) {
            console.error('Warehouse error:', error);
        }
    }

    async loadInventory() {
        this.isLoading = true;
        this.error = null;

        try {
            const data = await getInventoryRecords({
                searchTerm: this.searchTerm,
                reorderStatusFilter: this.reorderStatusFilter
            });

            this.inventoryData = (data || []).map(item => ({
                ...item,
                productLink: item.productId
                    ? `/lightning/r/Product2/${item.productId}/view`
                    : '',
                statusClass:
                    item.reorderStatus === 'Reorder Needed'
                        ? 'slds-text-color_error'
                        : item.reorderStatus === 'At Risk'
                            ? 'slds-text-color_warning'
                            : 'slds-text-color_success'
            }));

            this.applyFilters();

        } catch (error) {
            this.inventoryData = [];
            this.filteredData = [];

            this.error =
                error?.body?.message ||
                error?.message ||
                'Unable to load inventory.';
        } finally {
            this.isLoading = false;
        }
    }

    applyFilters() {
        let result = [...this.inventoryData];

        if (this.warehouseFilter !== 'All') {
            result = result.filter(
                item => item.warehouseId === this.warehouseFilter
            );
        }

        this.filteredData = result;
        this.sortData();
        this.currentPage = 1;
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;

        clearTimeout(this.searchTimeout);

        this.searchTimeout = setTimeout(() => {
            this.loadInventory();
        }, 400);
    }

    handleStatusFilterChange(event) {
        this.reorderStatusFilter = event.detail.value;
        this.loadInventory();
    }

    handleWarehouseFilterChange(event) {
        this.warehouseFilter = event.detail.value;
        this.applyFilters();
    }

    handleRefresh() {
        this.loadWarehouses();
        this.loadInventory();
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortedDirection = event.detail.sortDirection;
        this.sortData();
    }

    sortData() {
        const field = this.sortedBy;
        const multiplier = this.sortedDirection === 'asc' ? 1 : -1;

        this.filteredData = [...this.filteredData].sort((a, b) => {
            let x = a[field];
            let y = b[field];

            if (x == null) return 1;
            if (y == null) return -1;

            if (typeof x === 'number' && typeof y === 'number') {
                return (x - y) * multiplier;
            }

            return String(x).localeCompare(
                String(y),
                undefined,
                { numeric: true, sensitivity: 'base' }
            ) * multiplier;
        });
    }

    handleRowAction(event) {
        if (event.detail.action.name === 'view') {
            const row = event.detail.row;

            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: row.inventoryId,
                    actionName: 'view'
                }
            });
        }
    }

    handlePreviousPage() {
        if (this.currentPage > 1) {
            this.currentPage--;
        }
    }

    handleNextPage() {
        if (this.currentPage < this.totalPages) {
            this.currentPage++;
        }
    }

    get paginatedData() {
        const start = (this.currentPage - 1) * PAGE_SIZE;

        return this.filteredData.slice(start, start + PAGE_SIZE);
    }

    get totalPages() {
        return Math.max(
            1,
            Math.ceil(this.filteredData.length / PAGE_SIZE)
        );
    }

    get totalItems() {
        return this.filteredData.length;
    }

    get isFirstPage() {
        return this.currentPage === 1;
    }

    get isLastPage() {
        return this.currentPage >= this.totalPages;
    }

    get hasData() {
        return !this.isLoading &&
            !this.error &&
            this.filteredData.length > 0;
    }

    get isEmpty() {
        return !this.isLoading &&
            !this.error &&
            this.filteredData.length === 0;
    }

    get reorderNeededCount() {
        return this.filteredData.filter(
            item => item.reorderStatus === 'Reorder Needed'
        ).length;
    }

    get atRiskCount() {
        return this.filteredData.filter(
            item => item.reorderStatus === 'At Risk'
        ).length;
    }

    get healthyCount() {
        return this.filteredData.filter(
            item => item.reorderStatus === 'Healthy'
        ).length;
    }
}
