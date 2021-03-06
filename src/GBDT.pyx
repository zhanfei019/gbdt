import numpy as np
cimport numpy as cnp
from tqdm import tqdm
from collections import defaultdict
from sklearn.tree import DecisionTreeRegressor

from libcpp cimport bool
from libcpp.vector cimport vector

ctypedef cnp.double_t DTYPE_t
ctypedef cnp.int64_t DTYPE_i

cdef extern from "../tree/ClassificationTree.h":
    cdef cppclass ClassificationTree:
        ClassificationTree(const vector[vector[double]] & x,
                           const vector[int] & y,
                           const vector[double] & sample_weight,
                           int min_samples_leaf,
                           int max_depth);
        vector[int] predict(const vector[vector[double]] & x);
        vector[vector[double]] predict_proba(const vector[vector[double]] & x);

        const vector[vector[double]] x;
        const vector[int] y;
        int n_features;
        int nlevs;
        vector[int] Beg, End;
        vector[int] Pred, Cl, Cr, Spvb;
        vector[double] Ws;
        vector[bool] Leaf;
        vector[double] Spva;
        vector[int] Depth;

cdef class TreeClassification:
    cdef ClassificationTree * _thisptr

    def __cinit__(self,
                  cnp.ndarray[DTYPE_t, ndim=2] x,
                  cnp.ndarray[DTYPE_i, ndim=1] y,
                  sample_weight=None,
                  int min_samples_leaf=2,
                  int max_depth=-1):
        _x = np.transpose(x)
        if sample_weight is None:
            sample_weight = np.ones((len(y)), dtype=np.double)
        else:
            sample_weight = np.array(sample_weight, dtype=np.double).reshape(-1)
        self._thisptr = new ClassificationTree(_x, y, sample_weight, min_samples_leaf, max_depth)
        if self._thisptr == NULL:
            raise MemoryError()

    def __dealloc__(self):
        if self._thisptr != NULL:
            del self._thisptr

    @property
    def _n_levels(self):
        return self._thisptr.nlevs

    @property
    def x(self):
        return np.transpose(self._thisptr.x)

    @property
    def y(self):
        return np.asarray(self._thisptr.y, int)

    @property
    def n_features(self):
        return self._thisptr.n_features

    @property
    def tree_(self):
        mtree = {'v1cl': self._thisptr.Cl,
                 'v2cr': self._thisptr.Cr,
                 'v3spvb': self._thisptr.Spvb,
                 'v4spva': self._thisptr.Spva,
                 'v5ws': self._thisptr.Ws,
                 'v6pred': self._thisptr.Pred,
                 'v7leaf': self._thisptr.Leaf,
                 'v8beg': self._thisptr.Beg,
                 'v9end': self._thisptr.End,
                 'v10depth': self._thisptr.Depth}
        return mtree

    def predict(self, x):
        if np.ndim(x) != 2:
            x = np.reshape(x, (1, -1))
        assert x.shape[1] == self.n_features, "x.shape[1] must match n_features."
        return np.asarray(self._thisptr.predict(x), int)

    def predict_proba(self, x):
        if np.ndim(x) != 2:
            x = np.reshape(x, (1, -1))
        assert x.shape[1] == self.n_features, "x.shape[1] must match n_features."
        return np.atleast_2d(self._thisptr.predict_proba(x))

    def __call__(self, x):
        return self.predict(x)

class GBDTClassifier(object):
    def __init__(self, 
                 learning_rate=0.1,
                 n_estimators=100, 
                 min_samples_split=2, 
                 min_samples_leaf=1, 
                 min_weight_fraction_leaf=0.0, 
                 max_depth=3, 
                 min_impurity_decrease=0.0, 
                 min_impurity_split=None, 
                 max_leaf_nodes=None):
        self.learning_rate = learning_rate
        self.n_estimators = n_estimators
        self.min_samples_split = min_samples_split
        self.min_samples_leaf = min_samples_leaf
        self.min_weight_fraction_leaf = min_weight_fraction_leaf 
        self.max_depth = max_depth
        self.min_impurity_decrease = min_impurity_decrease
        self.min_impurity_split = min_impurity_split
        self.max_leaf_nodes = max_leaf_nodes
        
    def _init_estimator(self, x):
        return np.zeros(x.shape[0])

    def fit(self, x, y):
        self.n_data, self.n_features = x.shape
        self.x = np.asarray(x)
        self.y = np.asarray(y)
        self._unique_y = np.unique(y)
        self.K = len(self._unique_y)
        map_y = dict(zip(self._unique_y, np.arange(self.K)))
        self._y = np.array([map_y[iy] for iy in self.y], dtype=int)
        self.estimators_ = np.empty((self.n_estimators, self.K), dtype=np.object)
        self.values_ = np.empty((self.n_estimators, self.K), dtype=np.object)
        _F = np.asarray([self._init_estimator(self.x)] * self.K)
        for m in tqdm(range(self.n_estimators)):
            exp_Fs = np.exp(_F - np.max(_F, axis=0))
            exp_Fsum = np.sum(exp_Fs, axis=0)
            pk = exp_Fs / exp_Fsum
            for k in range(self.K):
                yk = (self._y == k) - pk[k]
                tree = DecisionTreeRegressor(min_samples_split=self.min_samples_split,
                                             min_samples_leaf=self.min_samples_leaf,
                                             min_weight_fraction_leaf=self.min_weight_fraction_leaf, 
                                             max_depth=self.max_depth,
                                             min_impurity_decrease=self.min_impurity_decrease,
                                             min_impurity_split=self.min_impurity_split,
                                             max_leaf_nodes=self.max_leaf_nodes)
                tree.fit(self.x, yk)
                nodes = tree.apply(self.x)
                map_nodes = defaultdict(list)
                for i in range(self.n_data):
                    map_nodes[nodes[i]].append(i)
                values_ = dict()
                for node, indexs in map_nodes.items():
                    _yk = yk[indexs]
                    abs_yk = np.abs(_yk)
                    gamma = (self.K - 1) / self.K * np.sum(_yk) / (np.sum(abs_yk * (1 - abs_yk)) + 1e-10)
                    values_[node] = self.learning_rate * gamma
                self.estimators_[m][k] = tree
                self.values_[m][k] = values_
                _F[k] = _F[k] + np.array([values_[node] for node in nodes])

    def _predict(self, x, i):
        preds = np.zeros((self.K, x.shape[0]), dtype=float)
        for k in range(self.K):
            estimator = self.estimators_[i][k]
            values = self.values_[i][k]
            nodes = estimator.apply(x)
            preds[k] = np.array([values[node] for node in nodes], dtype=float)
        return preds

    def predict(self, x):
        if np.ndim(x) != 2:
            x = np.reshape(x, (1, -1))
        assert x.shape[1] == self.n_features, "x.shape[1] must match n_features."
        preds = np.zeros((self.K, x.shape[0]), dtype=float)
        for i in range(self.n_estimators):
            preds += self._predict(x, i)

        preds = np.argmax(preds, axis=0)
        trans_preds = np.array([self._unique_y[pred] for pred in preds])
        return trans_preds