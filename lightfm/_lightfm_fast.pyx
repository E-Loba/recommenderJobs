#!python
#cython: boundscheck=False, wraparound=False, cdivision=True, initializedcheck=False

import numpy as np

cimport cython.operator.dereference as deref
from libc.stdlib cimport free, malloc

{openmp_import}


ctypedef float flt

# Allow sequential code blocks in a parallel setting.
# Used for applying full regularization in parallel blocks.
{lock_init}


cdef flt MAX_REG_SCALE = 1000000.0


cdef extern from "math.h" nogil:
    double sqrt(double)
    double exp(double)
    double log(double)
    double floor(double)
    double fabs(double)


cdef extern from "stdlib.h" nogil:
    ctypedef void const_void "const void"
    void qsort(void *base, int nmemb, int size,
               int(*compar)(const_void *, const_void *)) nogil
    void* bsearch(const void *key, void *base, int nmemb, int size,
                  int(*compar)(const_void *, const_void *)) nogil


# The rand_r implementation included below is a translation of the musl
# implementation (http://www.musl-libc.org/), which is licensed
# under the MIT license:

# ----------------------------------------------------------------------
# Copyright © 2005-2014 Rich Felker, et al.

# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:

# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
# ----------------------------------------------------------------------

cdef unsigned int temper(unsigned int x) nogil:

    cdef unsigned int and_1, and_2

    and_1 = 0x9D2C5680
    and_2 = 0xEFC60000

    x = x ^ (x >> 11)
    x = x ^ (x << 7 & and_1)
    x = x ^ (x << 15 & and_2)
    x = x ^ (x >> 18)

    return x


cdef int rand_r(unsigned int * seed) nogil:
    seed[0] = seed[0] * 1103515245 + 12345
    return temper(seed[0]) / 2


cdef int sample_range(int min_val, int max_val, unsigned int *seed) nogil:

    cdef int val_range

    val_range = max_val - min_val

    return min_val + (rand_r(seed) % val_range)


cdef int int_min(int x, int y) nogil:

    if x < y:
        return x
    else:
        return y


cdef int int_max(int x, int y) nogil:

    if x < y:
        return y
    else:
        return x


cdef struct Pair:
    int idx
    flt val


cdef int reverse_pair_compare(const_void *a, const_void *b) nogil:

    cdef flt diff

    diff = ((<Pair*>a)).val - ((<Pair*>b)).val
    if diff < 0:
        return 1
    else:
        return -1


cdef int int_compare(const_void *a, const_void *b) nogil:

    if deref(<int*>a) - deref(<int*>b) > 0:
        return 1
    elif deref(<int*>a) - deref(<int*>b) < 0:
        return -1
    else:
        return 0


cdef int flt_compare(const_void *a, const_void *b) nogil:

    if deref(<flt*>a) - deref(<flt*>b) > 0:
        return 1
    elif deref(<flt*>a) - deref(<flt*>b) < 0:
        return -1
    else:
        return 0


cdef class CSRMatrix:
    """
    Utility class for accessing elements
    of a CSR matrix.
    """

    cdef int[::1] indices
    cdef int[::1] indptr
    cdef flt[::1] data

    cdef int rows
    cdef int cols
    cdef int nnz

    def __init__(self, csr_matrix):

        self.indices = csr_matrix.indices
        self.indptr = csr_matrix.indptr
        self.data = csr_matrix.data

        self.rows, self.cols = csr_matrix.shape
        self.nnz = len(self.data)

    cdef int get_row_start(self, int row) nogil:
        """
        Return the pointer to the start of the
        data for row.
        """

        return self.indptr[row]

    cdef int get_row_end(self, int row) nogil:
        """
        Return the pointer to the end of the
        data for row.
        """

        return self.indptr[row + 1]


cdef class FastLightFM:
    """
    Class holding all the model state.
    """

    cdef flt[:, ::1] item_features
    cdef flt[:, ::1] item_feature_gradients
    cdef flt[:, ::1] item_feature_momentum

    cdef flt[::1] item_biases
    cdef flt[::1] item_bias_gradients
    cdef flt[::1] item_bias_momentum

    cdef flt[:, ::1] user_features
    cdef flt[:, ::1] user_feature_gradients
    cdef flt[:, ::1] user_feature_momentum

    cdef flt[::1] user_biases
    cdef flt[::1] user_bias_gradients
    cdef flt[::1] user_bias_momentum

    cdef int no_components
    cdef int adadelta
    cdef flt learning_rate
    cdef flt rho
    cdef flt eps
    cdef int max_sampled

    cdef double item_scale
    cdef double user_scale

    def __init__(self,
                 flt[:, ::1] item_features,
                 flt[:, ::1] item_feature_gradients,
                 flt[:, ::1] item_feature_momentum,
                 flt[::1] item_biases,
                 flt[::1] item_bias_gradients,
                 flt[::1] item_bias_momentum,
                 flt[:, ::1] user_features,
                 flt[:, ::1] user_feature_gradients,
                 flt[:, ::1] user_feature_momentum,
                 flt[::1] user_biases,
                 flt[::1] user_bias_gradients,
                 flt[::1] user_bias_momentum,
                 int no_components,
                 int adadelta,
                 flt learning_rate,
                 flt rho,
                 flt epsilon,
                 int max_sampled):

        self.item_features = item_features
        self.item_feature_gradients = item_feature_gradients
        self.item_feature_momentum = item_feature_momentum
        self.item_biases = item_biases
        self.item_bias_gradients = item_bias_gradients
        self.item_bias_momentum = item_bias_momentum
        self.user_features = user_features
        self.user_feature_gradients = user_feature_gradients
        self.user_feature_momentum = user_feature_momentum
        self.user_biases = user_biases
        self.user_bias_gradients = user_bias_gradients
        self.user_bias_momentum = user_bias_momentum

        self.no_components = no_components
        self.learning_rate = learning_rate
        self.rho = rho
        self.eps = epsilon

        self.item_scale = 1.0
        self.user_scale = 1.0

        self.adadelta = adadelta

        self.max_sampled = max_sampled


cdef inline flt sigmoid(flt v) nogil:
    """
    Compute the sigmoid of v.
    """

    return 1.0 / (1.0 + exp(-v))


cdef inline int in_positives(int item_id, int user_id, CSRMatrix interactions) nogil:

    cdef int i, start_idx, stop_idx

    start_idx = interactions.get_row_start(user_id)
    stop_idx = interactions.get_row_end(user_id)

    if bsearch(&item_id,
               &interactions.indices[start_idx],
               stop_idx - start_idx,
               sizeof(int),
               int_compare) == NULL:
        return 0
    else:
        return 1


cdef inline void compute_representation(CSRMatrix features,
                                        flt[:, ::1] feature_embeddings,
                                        flt[::1] feature_biases,
                                        FastLightFM lightfm,
                                        int row_id,
                                        double scale,
                                        flt *representation) nogil:
    """
    Compute latent representation for row_id.
    The last element of the representation is the bias.
    """

    cdef int i, j, start_index, stop_index, feature
    cdef flt feature_weight

    start_index = features.get_row_start(row_id)
    stop_index = features.get_row_end(row_id)

    for i in range(lightfm.no_components + 1):
        representation[i] = 0.0

    for i in range(start_index, stop_index):

        feature = features.indices[i]
        feature_weight = features.data[i] * scale

        for j in range(lightfm.no_components):

            representation[j] += feature_weight * feature_embeddings[feature, j]

        representation[lightfm.no_components] += feature_weight * feature_biases[feature]


cdef inline flt compute_prediction_from_repr(flt *user_repr,
                                             flt *item_repr,
                                             int no_components) nogil:

    cdef int i
    cdef flt result

    # Biases
    result = user_repr[no_components] + item_repr[no_components]

    # Latent factor dot product
    for i in range(no_components):
        result += user_repr[i] * item_repr[i]

    return result


cdef double update_biases(CSRMatrix feature_indices,
                          int start,
                          int stop,
                          flt[::1] biases,
                          flt[::1] gradients,
                          flt[::1] momentum,
                          double gradient,
                          int adadelta,
                          double learning_rate,
                          double alpha,
                          flt rho,
                          flt eps) nogil:
    """
    Perform a SGD update of the bias terms.
    """

    cdef int i, feature
    cdef double feature_weight, local_learning_rate, sum_learning_rate, update

    sum_learning_rate = 0.0

    if adadelta:
        for i in range(start, stop):

            feature = feature_indices.indices[i]
            feature_weight = feature_indices.data[i]

            gradients[feature] = rho * gradients[feature] + (1 - rho) * (feature_weight * gradient) ** 2
            local_learning_rate = sqrt(momentum[feature] + eps) / sqrt(gradients[feature] + eps)
            update = local_learning_rate * gradient * feature_weight
            momentum[feature] = rho * momentum[feature] + (1 - rho) * update ** 2
            biases[feature] -= update

            # Lazy regularization: scale up by the regularization
            # parameter.
            biases[feature] *= (1.0 + alpha * local_learning_rate)

            sum_learning_rate += local_learning_rate
    else:
        for i in range(start, stop):

            feature = feature_indices.indices[i]
            feature_weight = feature_indices.data[i]

            local_learning_rate = learning_rate / sqrt(gradients[feature])
            biases[feature] -= local_learning_rate * feature_weight * gradient
            gradients[feature] += (gradient * feature_weight) ** 2

            # Lazy regularization: scale up by the regularization
            # parameter.
            biases[feature] *= (1.0 + alpha * local_learning_rate)

            sum_learning_rate += local_learning_rate

    return sum_learning_rate


cdef inline double update_features(CSRMatrix feature_indices,
                                   flt[:, ::1] features,
                                   flt[:, ::1] gradients,
                                   flt[:, ::1] momentum,
                                   int component,
                                   int start,
                                   int stop,
                                   double gradient,
                                   int adadelta,
                                   double learning_rate,
                                   double alpha,
                                   flt rho,
                                   flt eps) nogil:
    """
    Update feature vectors.
    """

    cdef int i, feature,
    cdef double feature_weight, local_learning_rate, sum_learning_rate, update

    sum_learning_rate = 0.0

    if adadelta:
        for i in range(start, stop):

            feature = feature_indices.indices[i]
            feature_weight = feature_indices.data[i]

            gradients[feature, component] = (rho * gradients[feature, component]
                                             + (1 - rho) * (feature_weight * gradient) ** 2)
            local_learning_rate = (sqrt(momentum[feature, component] + eps)
                                   / sqrt(gradients[feature, component] + eps))
            update = local_learning_rate * gradient * feature_weight
            momentum[feature, component] = rho * momentum[feature, component] + (1 - rho) * update ** 2
            features[feature, component] -= update

            # Lazy regularization: scale up by the regularization
            # parameter.
            features[feature, component] *= (1.0 + alpha * local_learning_rate)

            sum_learning_rate += local_learning_rate
    else:
        for i in range(start, stop):

            feature = feature_indices.indices[i]
            feature_weight = feature_indices.data[i]

            local_learning_rate = learning_rate / sqrt(gradients[feature, component])
            features[feature, component] -= local_learning_rate * feature_weight * gradient
            gradients[feature, component] += (gradient * feature_weight) ** 2

            # Lazy regularization: scale up by the regularization
            # parameter.
            features[feature, component] *= (1.0 + alpha * local_learning_rate)

            sum_learning_rate += local_learning_rate

    return sum_learning_rate


cdef inline void update(double loss,
                        CSRMatrix item_features,
                        CSRMatrix user_features,
                        int user_id,
                        int item_id,
                        flt *user_repr,
                        flt *it_repr,
                        FastLightFM lightfm,
                        double item_alpha,
                        double user_alpha) nogil:
    """
    Apply the gradient step.
    """

    cdef int i, j, item_start_index, item_stop_index, user_start_index, user_stop_index
    cdef double avg_learning_rate
    cdef flt item_component, user_component

    avg_learning_rate = 0.0

    # Get the iteration ranges for features
    # for this training example.
    item_start_index = item_features.get_row_start(item_id)
    item_stop_index = item_features.get_row_end(item_id)

    user_start_index = user_features.get_row_start(user_id)
    user_stop_index = user_features.get_row_end(user_id)

    avg_learning_rate += update_biases(item_features, item_start_index, item_stop_index,
                                       lightfm.item_biases, lightfm.item_bias_gradients,
                                       lightfm.item_bias_momentum,
                                       loss,
                                       lightfm.adadelta,
                                       lightfm.learning_rate,
                                       item_alpha,
                                       lightfm.rho,
                                       lightfm.eps)
    avg_learning_rate += update_biases(user_features, user_start_index, user_stop_index,
                                       lightfm.user_biases, lightfm.user_bias_gradients,
                                       lightfm.user_bias_momentum,
                                       loss,
                                       lightfm.adadelta,
                                       lightfm.learning_rate,
                                       user_alpha,
                                       lightfm.rho,
                                       lightfm.eps)

    # Update latent representations.
    for i in range(lightfm.no_components):

        user_component = user_repr[i]
        item_component = it_repr[i]

        avg_learning_rate += update_features(item_features, lightfm.item_features,
                                             lightfm.item_feature_gradients,
                                             lightfm.item_feature_momentum,
                                             i, item_start_index, item_stop_index,
                                             loss * user_component,
                                             lightfm.adadelta,
                                             lightfm.learning_rate,
                                             item_alpha,
                                             lightfm.rho,
                                             lightfm.eps)
        avg_learning_rate += update_features(user_features, lightfm.user_features,
                                             lightfm.user_feature_gradients,
                                             lightfm.user_feature_momentum,
                                             i, user_start_index, user_stop_index,
                                             loss * item_component,
                                             lightfm.adadelta,
                                             lightfm.learning_rate,
                                             user_alpha,
                                             lightfm.rho,
                                             lightfm.eps)

    avg_learning_rate /= ((lightfm.no_components + 1) * (user_stop_index - user_start_index)
                          + (lightfm.no_components + 1) * (item_stop_index - item_start_index))

    # Update the scaling factors for lazy regularization, using the average learning rate
    # of features updated for this example.
    lightfm.item_scale *= (1.0 + item_alpha * avg_learning_rate)
    lightfm.user_scale *= (1.0 + user_alpha * avg_learning_rate)


cdef void warp_update(double loss,
                      CSRMatrix item_features,
                      CSRMatrix user_features,
                      int user_id,
                      int positive_item_id,
                      int negative_item_id,
                      flt *user_repr,
                      flt *pos_it_repr,
                      flt *neg_it_repr,
                      FastLightFM lightfm,
                      double item_alpha,
                      double user_alpha) nogil:
    """
    Apply the gradient step.
    """

    cdef int i, j, positive_item_start_index, positive_item_stop_index
    cdef int  user_start_index, user_stop_index, negative_item_start_index, negative_item_stop_index
    cdef double avg_learning_rate
    cdef flt positive_item_component, negative_item_component, user_component

    avg_learning_rate = 0.0

    # Get the iteration ranges for features
    # for this training example.
    positive_item_start_index = item_features.get_row_start(positive_item_id)
    positive_item_stop_index = item_features.get_row_end(positive_item_id)

    negative_item_start_index = item_features.get_row_start(negative_item_id)
    negative_item_stop_index = item_features.get_row_end(negative_item_id)

    user_start_index = user_features.get_row_start(user_id)
    user_stop_index = user_features.get_row_end(user_id)

    avg_learning_rate += update_biases(item_features, positive_item_start_index,
                                       positive_item_stop_index,
                                       lightfm.item_biases, lightfm.item_bias_gradients,
                                       lightfm.item_bias_momentum,
                                       -loss,
                                       lightfm.adadelta,
                                       lightfm.learning_rate,
                                       item_alpha,
                                       lightfm.rho,
                                       lightfm.eps)
    avg_learning_rate += update_biases(item_features, negative_item_start_index,
                                       negative_item_stop_index,
                                       lightfm.item_biases, lightfm.item_bias_gradients,
                                       lightfm.item_bias_momentum,
                                       loss,
                                       lightfm.adadelta,
                                       lightfm.learning_rate,
                                       item_alpha,
                                       lightfm.rho,
                                       lightfm.eps)
    avg_learning_rate += update_biases(user_features, user_start_index, user_stop_index,
                                       lightfm.user_biases, lightfm.user_bias_gradients,
                                       lightfm.user_bias_momentum,
                                       loss,
                                       lightfm.adadelta,
                                       lightfm.learning_rate,
                                       user_alpha,
                                       lightfm.rho,
                                       lightfm.eps)

    # Update latent representations.
    for i in range(lightfm.no_components):

        user_component = user_repr[i]
        positive_item_component = pos_it_repr[i]
        negative_item_component = neg_it_repr[i]

        avg_learning_rate += update_features(item_features, lightfm.item_features,
                                             lightfm.item_feature_gradients,
                                             lightfm.item_feature_momentum,
                                             i, positive_item_start_index, positive_item_stop_index,
                                             -loss * user_component,
                                             lightfm.adadelta,
                                             lightfm.learning_rate,
                                             item_alpha,
                                             lightfm.rho,
                                             lightfm.eps)
        avg_learning_rate += update_features(item_features, lightfm.item_features,
                                             lightfm.item_feature_gradients,
                                             lightfm.item_feature_momentum,
                                             i, negative_item_start_index, negative_item_stop_index,
                                             loss * user_component,
                                             lightfm.adadelta,
                                             lightfm.learning_rate,
                                             item_alpha,
                                             lightfm.rho,
                                             lightfm.eps)
        avg_learning_rate += update_features(user_features, lightfm.user_features,
                                             lightfm.user_feature_gradients,
                                             lightfm.user_feature_momentum,
                                             i, user_start_index, user_stop_index,
                                             loss * (negative_item_component -
                                                     positive_item_component),
                                             lightfm.adadelta,
                                             lightfm.learning_rate,
                                             user_alpha,
                                             lightfm.rho,
                                             lightfm.eps)

    avg_learning_rate /= ((lightfm.no_components + 1) * (user_stop_index - user_start_index)
                          + (lightfm.no_components + 1) *
                          (positive_item_stop_index - positive_item_start_index)
                          + (lightfm.no_components + 1)
                          * (negative_item_stop_index - negative_item_start_index))

    # Update the scaling factors for lazy regularization, using the average learning rate
    # of features updated for this example.
    lightfm.item_scale *= (1.0 + item_alpha * avg_learning_rate)
    lightfm.user_scale *= (1.0 + user_alpha * avg_learning_rate)


cdef void regularize(FastLightFM lightfm,
                     double item_alpha,
                     double user_alpha) nogil:
    """
    Apply accumulated L2 regularization to all features.
    """

    cdef int i, j
    cdef int no_features = lightfm.item_features.shape[0]
    cdef int no_users = lightfm.user_features.shape[0]

    for i in range(no_features):
        for j in range(lightfm.no_components):
            lightfm.item_features[i, j] /= lightfm.item_scale

        lightfm.item_biases[i] /= lightfm.item_scale

    for i in range(no_users):
        for j in range(lightfm.no_components):
            lightfm.user_features[i, j] /= lightfm.user_scale
        lightfm.user_biases[i] /= lightfm.user_scale

    lightfm.item_scale = 1.0
    lightfm.user_scale = 1.0


cdef void locked_regularize(FastLightFM lightfm,
                            double item_alpha,
                            double user_alpha) nogil:
    """
    Apply accumulated L2 regularization to all features. Acquire a lock
    to prevent multiple threads from performing this operation.
    """

    {lock_acquire}
    if lightfm.item_scale > MAX_REG_SCALE or lightfm.user_scale > MAX_REG_SCALE:
        regularize(lightfm,
                   item_alpha,
                   user_alpha)
    {lock_release}


def fit_logistic(CSRMatrix item_features,
                 CSRMatrix user_features,
                 int[::1] user_ids,
                 int[::1] item_ids,
                 flt[::1] Y,
                 flt[::1] sample_weight,
                 int[::1] shuffle_indices,
                 FastLightFM lightfm,
                 double learning_rate,
                 double item_alpha,
                 double user_alpha,
                 int num_threads):
    """
    Fit the LightFM model.
    """

    cdef int i, no_examples, user_id, item_id, row
    cdef double prediction, loss
    cdef int y
    cdef flt y_row, weight
    cdef flt *user_repr
    cdef flt *it_repr

    no_examples = Y.shape[0]

    {nogil_block}

        user_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))

        for i in {range_block}(no_examples):

            row = shuffle_indices[i]

            user_id = user_ids[row]
            item_id = item_ids[row]
            weight = sample_weight[row]

            compute_representation(user_features,
                                   lightfm.user_features,
                                   lightfm.user_biases,
                                   lightfm,
                                   user_id,
                                   lightfm.user_scale,
                                   user_repr)
            compute_representation(item_features,
                                   lightfm.item_features,
                                   lightfm.item_biases,
                                   lightfm,
                                   item_id,
                                   lightfm.item_scale,
                                   it_repr)

            prediction = sigmoid(compute_prediction_from_repr(user_repr,
                                                              it_repr,
                                                              lightfm.no_components))

            # Any value less or equal to zero
            # is a negative interaction.
            y_row = Y[row]
            if y_row <= 0:
                y = 0
            else:
                y = 1

            loss = weight * (prediction - y)
            update(loss,
                   item_features,
                   user_features,
                   user_id,
                   item_id,
                   user_repr,
                   it_repr,
                   lightfm,
                   item_alpha,
                   user_alpha)

            if lightfm.item_scale > MAX_REG_SCALE or lightfm.user_scale > MAX_REG_SCALE:
                locked_regularize(lightfm,
                                  item_alpha,
                                  user_alpha)

        free(user_repr)
        free(it_repr)

    regularize(lightfm,
               item_alpha,
               user_alpha)


def fit_warp(CSRMatrix item_features,
             CSRMatrix user_features,
             CSRMatrix interactions,
             int[::1] user_ids,
             int[::1] item_ids,
             flt[::1] Y,
             flt[::1] sample_weight,
             int[::1] shuffle_indices,
             FastLightFM lightfm,
             double learning_rate,
             double item_alpha,
             double user_alpha,
             int num_threads,
             random_state):
    """
    Fit the model using the WARP loss.
    """

    cdef int i, no_examples, user_id, positive_item_id, gamma
    cdef int negative_item_id, sampled, row
    cdef double positive_prediction, negative_prediction
    cdef double loss, MAX_LOSS
    cdef flt weight
    cdef flt *user_repr
    cdef flt *pos_it_repr
    cdef flt *neg_it_repr
    cdef unsigned int[::1] random_states

    random_states = random_state.randint(0,
                                         np.iinfo(np.int32).max,
                                         size=num_threads).astype(np.uint32)

    no_examples = Y.shape[0]
    MAX_LOSS = 10.0

    {nogil_block}

        user_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        pos_it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        neg_it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))

        for i in {range_block}(no_examples):
            row = shuffle_indices[i]

            user_id = user_ids[row]
            positive_item_id = item_ids[row]

            if not Y[row] > 0:
                continue

            weight = sample_weight[row]

            compute_representation(user_features,
                                   lightfm.user_features,
                                   lightfm.user_biases,
                                   lightfm,
                                   user_id,
                                   lightfm.user_scale,
                                   user_repr)
            compute_representation(item_features,
                                   lightfm.item_features,
                                   lightfm.item_biases,
                                   lightfm,
                                   positive_item_id,
                                   lightfm.item_scale,
                                   pos_it_repr)

            positive_prediction = compute_prediction_from_repr(user_repr,
                                                               pos_it_repr,
                                                               lightfm.no_components)

            sampled = 0

            while sampled < lightfm.max_sampled:

                sampled = sampled + 1
                negative_item_id = (rand_r(&random_states[{thread_num}])
                                    % item_features.rows)

                compute_representation(item_features,
                                       lightfm.item_features,
                                       lightfm.item_biases,
                                       lightfm,
                                       negative_item_id,
                                       lightfm.item_scale,
                                       neg_it_repr)

                negative_prediction = compute_prediction_from_repr(user_repr,
                                                                   neg_it_repr,
                                                                   lightfm.no_components)

                if negative_prediction > positive_prediction - 1:

                    # Sample again if the sample negative is actually a positive
                    if in_positives(negative_item_id, user_id, interactions):
                        continue

                    loss = weight * log(max(1.0, floor((item_features.rows - 1) / sampled)))

                    # Clip gradients for numerical stability.
                    if loss > MAX_LOSS:
                        loss = MAX_LOSS

                    warp_update(loss,
                                item_features,
                                user_features,
                                user_id,
                                positive_item_id,
                                negative_item_id,
                                user_repr,
                                pos_it_repr,
                                neg_it_repr,
                                lightfm,
                                item_alpha,
                                user_alpha)
                    break

            if lightfm.item_scale > MAX_REG_SCALE or lightfm.user_scale > MAX_REG_SCALE:
                locked_regularize(lightfm,
                                  item_alpha,
                                  user_alpha)

        free(user_repr)
        free(pos_it_repr)
        free(neg_it_repr)

    regularize(lightfm,
               item_alpha,
               user_alpha)

def fit_jobs(CSRMatrix item_features,
             CSRMatrix user_features,
             CSRMatrix interactions,
             int[::1] user_ids,
             int[::1] item_ids,
             flt[::1] Y,
             flt[::1] sample_weight,
             int[::1] shuffle_indices,
             FastLightFM lightfm,
             double learning_rate,
             double item_alpha,
             double user_alpha,
             int num_threads,
             random_state,
             flt max_data_val):
    """
    Fit the model using the WARP loss.
    """

    cdef int i, no_examples, user_id, positive_item_id, gamma
    cdef int negative_item_id, sampled, row
    cdef double positive_prediction, negative_prediction
    cdef double loss, MAX_LOSS
    cdef flt weight
    cdef flt *user_repr
    cdef flt *pos_it_repr
    cdef flt *neg_it_repr
    cdef unsigned int[::1] random_states
    cdef bint do_loss, pred_up, truth_up, do_reverse
    cdef int counter, index_item, index_user
    cdef flt rank_diff

    random_states = random_state.randint(0,
                                         np.iinfo(np.int32).max,
                                         size=num_threads).astype(np.uint32)

    no_examples = Y.shape[0]
    MAX_LOSS = 10.0

    {nogil_block}

        user_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        pos_it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        neg_it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))

        for i in {range_block}(no_examples):
            row = shuffle_indices[i]

            user_id = user_ids[row]
            positive_item_id = item_ids[row]

            if not Y[row] > 0:
                continue

            weight = sample_weight[row]

            compute_representation(user_features,
                                   lightfm.user_features,
                                   lightfm.user_biases,
                                   lightfm,
                                   user_id,
                                   lightfm.user_scale,
                                   user_repr)
            compute_representation(item_features,
                                   lightfm.item_features,
                                   lightfm.item_biases,
                                   lightfm,
                                   positive_item_id,
                                   lightfm.item_scale,
                                   pos_it_repr)

            positive_prediction = compute_prediction_from_repr(user_repr,
                                                               pos_it_repr,
                                                               lightfm.no_components)

            sampled = 0

            while sampled < lightfm.max_sampled:

                sampled = sampled + 1
                negative_item_id = (rand_r(&random_states[{thread_num}])
                                    % item_features.rows)
                compute_representation(item_features,
                                       lightfm.item_features,
                                       lightfm.item_biases,
                                       lightfm,
                                       negative_item_id,
                                       lightfm.item_scale,
                                       neg_it_repr)

                negative_prediction = compute_prediction_from_repr(user_repr,
                                                                   neg_it_repr,
                                                                   lightfm.no_components)

                do_reverse = False
                if in_positives(negative_item_id, user_id, interactions):
                    pred_up = negative_prediction > positive_prediction - 1
                    counter = 0
                    index_item = item_ids[counter]
                    index_user = user_ids[counter]
                    while not (index_item == negative_item_id) and not (index_user == user_id):
                        counter = counter + 1
                        index_item = item_ids[counter]
                        index_user = user_ids[counter]
                    truth_up = Y[counter] > Y[row]
                    #weight = weight * (abs(Y[row] - Y[counter]) / max_data_val)  # TODO
                    if pred_up and not truth_up:
                        do_loss = True
                        do_reverse = False
                    elif truth_up and not pred_up:
                        do_loss = True
                        do_reverse = True
                    else:
                        do_loss = False
                else:
                    #weight = weight * (Y[row] / max_data_val)  # TODO
                    if negative_prediction > positive_prediction - 1:
                        do_loss = True
                        do_reverse = False
                    else:
                        do_loss = False
                if do_loss:
                #if negative_prediction > positive_prediction - 1:
                    # Sample again if the sample negative is actually a positive
                    # if in_positives(negative_item_id, user_id, interactions):
                    #     continue
                    # if interactions[user_id,item_id] < interactions[user_id,negative_item_id]
                    #     #printf("%d\n", negative_item_id)
                    #     continue

                    loss = weight * log(max(1.0, floor((item_features.rows - 1) / sampled)))

                    # Clip gradients for numerical stability.
                    if loss > MAX_LOSS:
                        loss = MAX_LOSS

                    if do_reverse:
                        warp_update(loss,
                                    item_features,
                                    user_features,
                                    user_id,
                                    negative_item_id,  # swapped
                                    positive_item_id,  # swapped
                                    user_repr,
                                    neg_it_repr,       # swapped
                                    pos_it_repr,       # swapped
                                    lightfm,
                                    item_alpha,
                                    user_alpha)
                    else:
                        warp_update(loss,
                                    item_features,
                                    user_features,
                                    user_id,
                                    positive_item_id,
                                    negative_item_id,
                                    user_repr,
                                    pos_it_repr,
                                    neg_it_repr,
                                    lightfm,
                                    item_alpha,
                                    user_alpha)
                    break

            if lightfm.item_scale > MAX_REG_SCALE or lightfm.user_scale > MAX_REG_SCALE:
                locked_regularize(lightfm,
                                  item_alpha,
                                  user_alpha)

        free(user_repr)
        free(pos_it_repr)
        free(neg_it_repr)

    regularize(lightfm,
               item_alpha,
               user_alpha)


def fit_sigma(CSRMatrix item_features,
             CSRMatrix user_features,
             CSRMatrix interactions,
             int[::1] user_ids,
             int[::1] item_ids,
             flt[::1] Y,
             flt[::1] sample_weight,
             int[::1] shuffle_indices,
             FastLightFM lightfm,
             double learning_rate,
             double item_alpha,
             double user_alpha,
             int num_threads,
             random_state,
             flt max_data_val):
    """
    Fit the model using the WARP loss.
    """

    cdef int i, no_examples, user_id, positive_item_id, gamma, dummy_i
    cdef int negative_item_id, sampled, row
    cdef double positive_prediction, negative_prediction, max_prediction, temp_pred
    cdef double loss, MAX_LOSS
    cdef flt weight, delta_
    cdef flt *user_repr
    cdef flt *pos_it_repr
    cdef flt *neg_it_repr
    cdef flt *temp_usr_repr
    cdef flt *temp_itm_repr
    cdef unsigned int[::1] random_states
    cdef bint do_loss, pred_up, truth_up, do_reverse
    cdef int counter, index_item, index_user
    cdef flt rank_diff

    random_states = random_state.randint(0,
                                         np.iinfo(np.int32).max,
                                         size=num_threads).astype(np.uint32)

    no_examples = Y.shape[0]
    MAX_LOSS = 10.0
    max_prediction = 0.0

    {nogil_block}

        user_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        pos_it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        neg_it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))

        for i in {range_block}(no_examples):
            row = shuffle_indices[i]

            user_id = user_ids[row]
            positive_item_id = item_ids[row]
            if not Y[row] > 0:
                continue

            weight = sample_weight[row]

            compute_representation(user_features,
                                   lightfm.user_features,
                                   lightfm.user_biases,
                                   lightfm,
                                   user_id,
                                   lightfm.user_scale,
                                   user_repr)
            compute_representation(item_features,
                                   lightfm.item_features,
                                   lightfm.item_biases,
                                   lightfm,
                                   positive_item_id,
                                   lightfm.item_scale,
                                   pos_it_repr)
            max_prediction = 0.0
            for dummy_i in range(no_examples):
                compute_representation(user_features,
                                        lightfm.user_features,
                                        lightfm.user_biases,
                                        lightfm,
                                        user_ids[dummy_i],
                                        lightfm.user_scale,
                                        temp_usr_repr)
                
                compute_representation(item_features,
                                        lightfm.item_features,
                                        lightfm.item_biases,
                                        lightfm,
                                        item_ids[dummy_i],
                                        lightfm.item_scale,
                                        temp_itm_repr)
                temp_pred = compute_prediction_from_repr(temp_usr_repr,
                                                        temp_itm_repr,
                                                        lightfm.no_components)
                max_prediction = max(max_prediction, temp_pred)
            positive_prediction = compute_prediction_from_repr(user_repr,
                                                               pos_it_repr,
                                                               lightfm.no_components)
            sampled = 0

            while sampled < lightfm.max_sampled:

                sampled = sampled + 1
                negative_item_id = (rand_r(&random_states[{thread_num}])
                                    % item_features.rows)
                compute_representation(item_features,
                                       lightfm.item_features,
                                       lightfm.item_biases,
                                       lightfm,
                                       negative_item_id,
                                       lightfm.item_scale,
                                       neg_it_repr)

                negative_prediction = compute_prediction_from_repr(user_repr,
                                                                   neg_it_repr,
                                                                   lightfm.no_components)

                do_reverse = False
                if in_positives(negative_item_id, user_id, interactions):
                    pred_up = negative_prediction > positive_prediction - 1
                    counter = 0
                    index_item = item_ids[counter]
                    index_user = user_ids[counter]
                    while not (index_item == negative_item_id) and not (index_user == user_id):
                        counter = counter + 1
                        index_item = item_ids[counter]
                        index_user = user_ids[counter]
                    truth_up = Y[counter] > Y[row]
                    if pred_up and not truth_up:
                        do_loss = True
                        do_reverse = False
                    elif truth_up and not pred_up:
                        do_loss = True
                        do_reverse = True
                    else:
                        do_loss = False
                        if truth_up:
                            do_reverse = True
                        else:
                            do_reverse = False
                else:
                    if negative_prediction > positive_prediction - 1:
                        do_loss = True
                        do_reverse = False
                    else:
                        do_loss = False
                        do_reverse = False
                loss = 0
                if do_loss:
                    loss = loss + weight * log(max(1.0, floor((item_features.rows - 1) / sampled)))
                else:
                    delta_ = fabs(negative_prediction - positive_prediction)/max_prediction - fabs(Y[counter] - Y[row])/max_data_val
                    if delta_ > 0:
                        if truth_up:
                            do_reverse = True
                        else:
                            do_reverse = False
                    else:
                        if truth_up:
                            do_reverse = False
                        else:
                            do_reverse = True
                    loss = loss + weight * log(fabs(delta) + 1)
                # Clip gradients for numerical stability.
                if loss > MAX_LOSS:
                    loss = MAX_LOSS

                if do_reverse:
                    warp_update(loss,
                                item_features,
                                user_features,
                                user_id,
                                negative_item_id,  # swapped
                                positive_item_id,  # swapped
                                user_repr,
                                neg_it_repr,       # swapped
                                pos_it_repr,       # swapped
                                lightfm,
                                item_alpha,
                                user_alpha)
                else:
                    warp_update(loss,
                                item_features,
                                user_features,
                                user_id,
                                positive_item_id,
                                negative_item_id,
                                user_repr,
                                pos_it_repr,
                                neg_it_repr,
                                lightfm,
                                item_alpha,
                                user_alpha)
                if do_loss:
                    break

            if lightfm.item_scale > MAX_REG_SCALE or lightfm.user_scale > MAX_REG_SCALE:
                locked_regularize(lightfm,
                                  item_alpha,
                                  user_alpha)

        free(user_repr)
        free(pos_it_repr)
        free(neg_it_repr)

    regularize(lightfm,
               item_alpha,
               user_alpha)


def fit_warp_kos(CSRMatrix item_features,
                 CSRMatrix user_features,
                 CSRMatrix data,
                 int[::1] user_ids,
                 int[::1] shuffle_indices,
                 FastLightFM lightfm,
                 double learning_rate,
                 double item_alpha,
                 double user_alpha,
                 int k,
                 int n,
                 int num_threads,
                 random_state):
    """
    Fit the model using the WARP loss.
    """

    cdef int i, j, no_examples, user_id, positive_item_id, gamma
    cdef int negative_item_id, sampled, row, sampled_positive_item_id
    cdef int user_pids_start, user_pids_stop, no_positives, POS_SAMPLES
    cdef double positive_prediction, negative_prediction
    cdef double loss, MAX_LOSS, sampled_positive_prediction
    cdef flt *user_repr
    cdef flt *pos_it_repr
    cdef flt *neg_it_repr
    cdef Pair *pos_pairs
    cdef unsigned int[::1] random_states

    random_states = random_state.randint(0,
                                         np.iinfo(np.int32).max,
                                         size=num_threads).astype(np.uint32)

    no_examples = user_ids.shape[0]
    MAX_LOSS = 10.0

    {nogil_block}

        user_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        pos_it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        neg_it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        pos_pairs = <Pair*>malloc(sizeof(Pair) * n)

        for i in {range_block}(no_examples):
            row = shuffle_indices[i]
            user_id = user_ids[row]

            compute_representation(user_features,
                                   lightfm.user_features,
                                   lightfm.user_biases,
                                   lightfm,
                                   user_id,
                                   lightfm.user_scale,
                                   user_repr)

            user_pids_start = data.get_row_start(user_id)
            user_pids_stop = data.get_row_end(user_id)

            if user_pids_stop == user_pids_start:
                continue

            # Sample k-th positive item
            no_positives = int_min(n, user_pids_stop - user_pids_start)
            for j in range(no_positives):
                sampled_positive_item_id = data.indices[sample_range(user_pids_start,
                                                                     user_pids_stop,
                                                                     &random_states[{thread_num}])]

                compute_representation(item_features,
                                       lightfm.item_features,
                                       lightfm.item_biases,
                                       lightfm,
                                       sampled_positive_item_id,
                                       lightfm.item_scale,
                                       pos_it_repr)

                sampled_positive_prediction = compute_prediction_from_repr(user_repr,
                                                                           pos_it_repr,
                                                                           lightfm.no_components)

                pos_pairs[j].idx = sampled_positive_item_id
                pos_pairs[j].val = sampled_positive_prediction

            qsort(pos_pairs,
                  no_positives,
                  sizeof(Pair),
                  reverse_pair_compare)

            positive_item_id = pos_pairs[int_min(k, no_positives) - 1].idx
            positive_prediction = pos_pairs[int_min(k, no_positives) - 1].val

            compute_representation(item_features,
                                   lightfm.item_features,
                                   lightfm.item_biases,
                                   lightfm,
                                   positive_item_id,
                                   lightfm.item_scale,
                                   pos_it_repr)

            # Move on to the WARP step
            sampled = 0

            while sampled < lightfm.max_sampled:

                sampled = sampled + 1
                negative_item_id = (rand_r(&random_states[{thread_num}])
                                    % item_features.rows)

                compute_representation(item_features,
                                       lightfm.item_features,
                                       lightfm.item_biases,
                                       lightfm,
                                       negative_item_id,
                                       lightfm.item_scale,
                                       neg_it_repr)

                negative_prediction = compute_prediction_from_repr(user_repr,
                                                                   neg_it_repr,
                                                                   lightfm.no_components)

                if negative_prediction > positive_prediction - 1:

                    if in_positives(negative_item_id, user_id, data):
                        continue

                    loss = log(floor((item_features.rows - 1) / sampled))

                    # Clip gradients for numerical stability.
                    if loss > MAX_LOSS:
                        loss = MAX_LOSS

                    warp_update(loss,
                                item_features,
                                user_features,
                                user_id,
                                positive_item_id,
                                negative_item_id,
                                user_repr,
                                pos_it_repr,
                                neg_it_repr,
                                lightfm,
                                item_alpha,
                                user_alpha)
                    break

            if lightfm.item_scale > MAX_REG_SCALE or lightfm.user_scale > MAX_REG_SCALE:
                locked_regularize(lightfm,
                                  item_alpha,
                                  user_alpha)

        free(user_repr)
        free(pos_it_repr)
        free(neg_it_repr)
        free(pos_pairs)

    regularize(lightfm,
               item_alpha,
               user_alpha)


def fit_bpr(CSRMatrix item_features,
            CSRMatrix user_features,
            CSRMatrix interactions,
            int[::1] user_ids,
            int[::1] item_ids,
            flt[::1] Y,
            flt[::1] sample_weight,
            int[::1] shuffle_indices,
            FastLightFM lightfm,
            double learning_rate,
            double item_alpha,
            double user_alpha,
            int num_threads,
            random_state):
    """
    Fit the model using the BPR loss.
    """

    cdef int i, j, no_examples, user_id, positive_item_id
    cdef int negative_item_id, sampled, row
    cdef double positive_prediction, negative_prediction
    cdef flt weight
    cdef unsigned int[::1] random_states
    cdef flt *user_repr
    cdef flt *pos_it_repr
    cdef flt *neg_it_repr

    random_states = random_state.randint(0,
                                         np.iinfo(np.int32).max,
                                         size=num_threads).astype(np.uint32)

    no_examples = Y.shape[0]

    {nogil_block}

        user_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        pos_it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        neg_it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))

        for i in {range_block}(no_examples):
            row = shuffle_indices[i]

            if not Y[row] > 0:
                continue

            weight = sample_weight[row]
            user_id = user_ids[row]
            positive_item_id = item_ids[row]

            for j in range(no_examples):
                negative_item_id = item_ids[(rand_r(&random_states[{thread_num}])
                                             % no_examples)]
                if not in_positives(negative_item_id, user_id, interactions):
                    break

            compute_representation(user_features,
                                   lightfm.user_features,
                                   lightfm.user_biases,
                                   lightfm,
                                   user_id,
                                   lightfm.user_scale,
                                   user_repr)
            compute_representation(item_features,
                                   lightfm.item_features,
                                   lightfm.item_biases,
                                   lightfm,
                                   positive_item_id,
                                   lightfm.item_scale,
                                   pos_it_repr)
            compute_representation(item_features,
                                   lightfm.item_features,
                                   lightfm.item_biases,
                                   lightfm,
                                   negative_item_id,
                                   lightfm.item_scale,
                                   neg_it_repr)

            positive_prediction = compute_prediction_from_repr(user_repr,
                                                               pos_it_repr,
                                                               lightfm.no_components)
            negative_prediction = compute_prediction_from_repr(user_repr,
                                                               neg_it_repr,
                                                               lightfm.no_components)

            warp_update(weight * (1.0 - sigmoid(positive_prediction - negative_prediction)),
                        item_features,
                        user_features,
                        user_id,
                        positive_item_id,
                        negative_item_id,
                        user_repr,
                        pos_it_repr,
                        neg_it_repr,
                        lightfm,
                        item_alpha,
                        user_alpha)

            if lightfm.item_scale > MAX_REG_SCALE or lightfm.user_scale > MAX_REG_SCALE:
                locked_regularize(lightfm,
                                  item_alpha,
                                  user_alpha)

        free(user_repr)
        free(pos_it_repr)
        free(neg_it_repr)

    regularize(lightfm,
               item_alpha,
               user_alpha)


def predict_lightfm(CSRMatrix item_features,
                    CSRMatrix user_features,
                    int[::1] user_ids,
                    int[::1] item_ids,
                    flt[::1] predictions,
                    FastLightFM lightfm,
                    int num_threads):
    """
    Generate predictions.
    """

    cdef int i, no_examples
    cdef flt *user_repr
    cdef flt *it_repr

    no_examples = predictions.shape[0]

    {nogil_block}

        user_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))

        for i in {range_block}(no_examples):

            compute_representation(user_features,
                                   lightfm.user_features,
                                   lightfm.user_biases,
                                   lightfm,
                                   user_ids[i],
                                   lightfm.user_scale,
                                   user_repr)
            compute_representation(item_features,
                                   lightfm.item_features,
                                   lightfm.item_biases,
                                   lightfm,
                                   item_ids[i],
                                   lightfm.item_scale,
                                   it_repr)

            predictions[i] = compute_prediction_from_repr(user_repr,
                                                          it_repr,
                                                          lightfm.no_components)

        free(user_repr)
        free(it_repr)


def predict_ranks(CSRMatrix item_features,
                  CSRMatrix user_features,
                  CSRMatrix test_interactions,
                  CSRMatrix train_interactions,
                  flt[::1] ranks,
                  FastLightFM lightfm,
                  int num_threads):
    """
    """

    cdef int i, j, user_id, item_id, predictions_size, row_start, row_stop
    cdef flt *user_repr
    cdef flt *it_repr
    cdef flt *predictions
    cdef flt prediction, rank

    predictions_size = 0

    # Figure out the max size of the predictions
    # buffer.
    for user_id in range(test_interactions.rows):
        predictions_size = int_max(predictions_size,
                                   test_interactions.get_row_end(user_id)
                                   - test_interactions.get_row_start(user_id))

    {nogil_block}

        user_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        it_repr = <flt *>malloc(sizeof(flt) * (lightfm.no_components + 1))
        item_ids = <int *>malloc(sizeof(int) * predictions_size)
        predictions = <flt *>malloc(sizeof(flt) * predictions_size)

        for user_id in {range_block}(test_interactions.rows):

            row_start = test_interactions.get_row_start(user_id)
            row_stop = test_interactions.get_row_end(user_id)

            if row_stop == row_start:
                # No test interactions for this user
                continue

            compute_representation(user_features,
                                   lightfm.user_features,
                                   lightfm.user_biases,
                                   lightfm,
                                   user_id,
                                   lightfm.user_scale,
                                   user_repr)

            # Compute predictions for the items whose
            # ranks we want to know
            for i in range(row_stop - row_start):

                item_id = test_interactions.indices[row_start + i]

                compute_representation(item_features,
                                       lightfm.item_features,
                                       lightfm.item_biases,
                                       lightfm,
                                       item_id,
                                       lightfm.item_scale,
                                       it_repr)

                item_ids[i] = item_id
                predictions[i] = compute_prediction_from_repr(user_repr,
                                                              it_repr,
                                                              lightfm.no_components)

            # Now we can zip through all the other items and compute ranks
            for item_id in range(test_interactions.cols):

                if in_positives(item_id, user_id, train_interactions):
                    continue

                compute_representation(item_features,
                                       lightfm.item_features,
                                       lightfm.item_biases,
                                       lightfm,
                                       item_id,
                                       lightfm.item_scale,
                                       it_repr)
                prediction = compute_prediction_from_repr(user_repr,
                                                          it_repr,
                                                          lightfm.no_components)

                for i in range(row_stop - row_start):
                    if item_id != item_ids[i] and prediction >= predictions[i]:
                        ranks[row_start + i] += 1.0

        free(user_repr)
        free(it_repr)
        free(predictions)


def calculate_auc_from_rank(CSRMatrix ranks,
                            int[::1] num_train_positives,
                            flt[::1] rank_data,
                            flt[::1] auc,
                            int num_threads):

    cdef int i, j, user_id, row_start, row_stop, num_negatives, num_positives
    cdef flt rank

    {nogil_block}
        for user_id in {range_block}(ranks.rows):

            row_start = ranks.get_row_start(user_id)
            row_stop = ranks.get_row_end(user_id)

            num_positives = row_stop - row_start
            num_negatives = ranks.cols - ((row_stop - row_start) + num_train_positives[user_id])

            # If there is only one class present,
            # return 0.5.
            if num_positives == 0 or num_negatives == ranks.cols:
                auc[user_id] = 0.5
                continue

            # Sort the positives according to
            # increasing rank.
            qsort(&rank_data[row_start],
                  num_positives,
                  sizeof(flt),
                  flt_compare)

            for i in range(num_positives):

                rank = ranks.data[row_start + i]

                # There are i other positives that
                # are higher-ranked, reduce the rank
                # by i. Ignore ties but ensure that
                # the resulting rank is nonnegative.
                rank = rank - i

                if rank < 0:
                    rank = 0

                # Number of negatives that rank above the current item
                # over the total number of negatives: the probability
                # of rank inversion.
                auc[user_id] += 1.0 - rank / num_negatives

            if num_positives != 0:
                auc[user_id] /= num_positives


# Expose test functions
def __test_in_positives(int row, int col, CSRMatrix mat):

    if in_positives(col, row, mat):
        return True
    else:
        return False
