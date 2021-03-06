% tc: time consumed
% p_level: predetermined level
% 존재하지 않을 경우 비워둠

function [boxes, tc] = detect_test_seq(input, model, thresh, p_level)

% Keep track of detected boxes and features
BOXCACHESIZE = 100000;
cnt = 0;
boxes.s  = 0;
boxes.c  = 0;
boxes.xy = 0;
boxes.level = 0;
boxes(BOXCACHESIZE) = boxes;

is_initial = 0;
if nargin < 4
    is_initial = 1;
    p_level = 0;
end

% Compute the feature pyramid and prepare filters
pyra = featpyramid(input,model);

[components,filters,resp]  = modelcomponents(model,pyra);

tc = zeros(length(components), 1);

for c  = randperm(length(components)),
    
    t_sum = 0;
    t1_sum = 0;
    t2_sum = 0;
    t3_sum = 0;
    
    fprintf('\n[timecheck] component # %d\n', c);
    
    minlevel = model.interval+1;
    levels   = minlevel:length(pyra.feat);
    for rlevel = levels(randperm(length(levels))),
        
        % 주어진 p_level 근처의 5개 level에 대해서만 detection을 수행하도록 함
        if is_initial
            % pass
        elseif rlevel < p_level-2 || rlevel > p_level+2
            % skip
            continue;
        end
        
        fprintf('[timecheck] level # %d\n', rlevel);

        parts    = components{c};
        numparts = length(parts);
        
        tic
        
        % Local part scores
        for k = 1:numparts,
            f     = parts(k).filterid;
            level = rlevel-parts(k).scale*model.interval;
            if isempty(resp{level}),
                resp{level} = fconv(pyra.feat{level},filters,1,length(filters));
                fprintf('fconv(%d) ', level);
            end
            parts(k).score = resp{level}{f};
            parts(k).level = level;
        end
        
        t1 = toc;
        t1_sum = t1_sum+t1;
        fprintf('%f ', t1);
        
        tic
        
        % Walk from leaves to root of tree, passing message to parent
        % Given a 2D array of filter scores 'child', shiftdt() does the following:
        % (1) Apply distance transform
        % (2) Shift by anchor position (child.startxy) of part wrt parent
        % (3) Downsample by child.step
        for k = numparts:-1:2,
            child = parts(k);
            par   = child.parent;
            [Ny,Nx,foo] = size(parts(par).score);
            [msg,parts(k).Ix,parts(k).Iy] = shiftdt(child.score, child.w(1),child.w(2),child.w(3),child.w(4), ...
                child.startx, child.starty, Nx, Ny, child.step);
            parts(par).score = parts(par).score + msg;
        end
        
        t2 = toc;
        t2_sum = t2_sum+t2;
        fprintf('%f ', t2);
        
        tic
        
        % Add bias to root score
        rscore = parts(1).score + parts(1).w;
        
        [Y,X] = find(rscore >= thresh);
        
        if ~isempty(X)
            XY = backtrack( X, Y, parts, pyra);
        end
        
        % Walk back down tree following pointers
        for i = 1:length(X)
            x = X(i);
            y = Y(i);
            
            if cnt == BOXCACHESIZE
                b0 = nms_face(boxes,0.3);
                clear boxes;
                boxes.s  = 0;
                boxes.c  = 0;
                boxes.xy = 0;
                boxes.level = 0;
                boxes(BOXCACHESIZE) = boxes;
                cnt = length(b0);
                boxes(1:cnt) = b0;
            end
            
            cnt = cnt + 1;
            boxes(cnt).c = c;
            boxes(cnt).s = rscore(y,x);
            boxes(cnt).level = rlevel;
            boxes(cnt).xy = XY(:,:,i);
        end
        
        t3 = toc;
        t3_sum = t3_sum+t3;
        fprintf('%f ', t3);
        
        fprintf('= %f\n', t1+t2+t3);
        
        t_sum = t_sum+t1+t2+t3;
    end
%     tc(c, 1) = toc;
    
    fprintf('%f + %f + %f = %f\n', t1_sum, t2_sum, t3_sum, t_sum);
end

boxes = boxes(1:cnt);


% Backtrack through dynamic programming messages to estimate part locations
% and the associated feature vector
function box = backtrack(x,y,parts,pyra)
numparts = length(parts);
ptr = zeros(numparts,2,length(x));
box = zeros(numparts,4,length(x));
k   = 1;
p   = parts(k);
ptr(k,1,:) = x;
ptr(k,2,:) = y;
% image coordinates of root
scale = pyra.scale(p.level);
padx  = pyra.padx;
pady  = pyra.pady;
box(k,1,:) = (x-1-padx)*scale + 1;
box(k,2,:) = (y-1-pady)*scale + 1;
box(k,3,:) = box(k,1,:) + p.sizx*scale - 1;
box(k,4,:) = box(k,2,:) + p.sizy*scale - 1;

for k = 2:numparts,
    p   = parts(k);
    par = p.parent;
    x   = ptr(par,1,:);
    y   = ptr(par,2,:);
    inds = sub2ind(size(p.Ix), y, x);
    ptr(k,1,:) = p.Ix(inds);
    ptr(k,2,:) = p.Iy(inds);
    % image coordinates of part k
    scale = pyra.scale(p.level);
    box(k,1,:) = (ptr(k,1,:)-1-padx)*scale + 1;
    box(k,2,:) = (ptr(k,2,:)-1-pady)*scale + 1;
    box(k,3,:) = box(k,1,:) + p.sizx*scale - 1;
    box(k,4,:) = box(k,2,:) + p.sizy*scale - 1;
end

% Cache various statistics from the model data structure for later use
function [components,filters,resp] = modelcomponents(model,pyra)
components = cell(length(model.components),1);
for c = 1:length(model.components),
    for k = 1:length(model.components{c}),
        p = model.components{c}(k);
        x = model.filters(p.filterid);
        [p.sizy p.sizx foo] = size(x.w);
        p.filterI = x.i;
        x = model.defs(p.defid);
        p.defI = x.i;
        p.w    = x.w;
        
        % store the scale of each part relative to the component root
        par = p.parent;
        assert(par < k);
        ax  = x.anchor(1);
        ay  = x.anchor(2);
        ds  = x.anchor(3);
        if par > 0,
            p.scale = ds + components{c}(par).scale;
        else
            assert(k == 1);
            p.scale = 0;
        end
        % amount of (virtual) padding to hallucinate
        step     = 2^ds;
        virtpady = (step-1)*pyra.pady;
        virtpadx = (step-1)*pyra.padx;
        % starting points (simulates additional padding at finer scales)
        p.starty = ay-virtpady;
        p.startx = ax-virtpadx;
        p.step   = step;
        p.level  = 0;
        p.score  = 0;
        p.Ix     = 0;
        p.Iy     = 0;
        components{c}(k) = p;
    end
end

resp    = cell(length(pyra.feat),1);
filters = cell(length(model.filters),1);
for i = 1:length(filters),
    filters{i} = model.filters(i).w;
end

